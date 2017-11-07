open Core
module Sparse = Owl.Sparse.Matrix.D

module Field = struct
  module T = struct
    type t
      =
      | F0
      | F1
      | F2
      | F3
      | F4
      | Meta0
      | Meta1
      | Meta2
      | Meta3
      | Meta4
      [@@deriving sexp, enumerate, enum, eq, hash]

    let num_fields = max + 1

    let order = Array.init num_fields ~f:ident

    (* compare depends on current order! *)
    let compare (x : t) (y : t) : int =
      (* using Obj.magic instead of to_enum for bettter performance *)
      Int.compare order.(Obj.magic x) order.(Obj.magic y)
  end

  include T
  module Map = Map.Make(T)

  type field = t

  let hash = Hashtbl.hash

  let of_string s =
    t_of_sexp (Sexp.of_string s)

  let to_string t =
    Sexp.to_string (sexp_of_t t)

  let is_valid_order (lst : t list) : bool =
    Set.Poly.(equal (of_list lst) (of_list all))

  let set_order (lst : t list) : unit =
    assert (is_valid_order lst);
    List.iteri lst ~f:(fun i fld -> order.(to_enum fld) <- i)

  (* Not a clean way to invert a permutation, but fast *)
  let invert arr =
    let inverted = Array.init num_fields ~f:ident in
    Array.iteri arr ~f:(fun i elt -> inverted.(elt) <- i );
    inverted

  let get_order () =
    Array.to_list (invert order)
    |> List.filter_map ~f:of_enum

  module type ENV = sig
    type t
    val empty : t
    exception Full
    val add : t -> string -> field Probnetkat.meta_init -> bool -> t (* may raise Full *)
    val lookup : t -> string -> field * (field Probnetkat.meta_init * bool) (* may raise Not_found *)
  end

  module Env : ENV = struct

    type t = {
      alist : (string * (field * (field Probnetkat.meta_init * bool))) list;
      depth : int
    }

    let empty = { alist = []; depth = 0 }

    exception Full

    let add env name init mut =
      let field =
        match env.depth with
        | 0 -> Meta0
        | 1 -> Meta1
        | 2 -> Meta2
        | 3 -> Meta3
        | 4 -> Meta4
        | _ -> raise Full
      in
      { alist = List.Assoc.add ~equal:(=) env.alist name (field, (init, mut));
        depth = env.depth + 1}

    let lookup env name =
      List.Assoc.find_exn ~equal:(=) env.alist name
  end
(*
  (* Heuristic to pick a variable order that operates by scoring the fields
     in a policy. A field receives a high score if, when a test field=X
     is false, the policy can be shrunk substantially.

     NOTE(arjun): This could be done better, but it seems to work quite well
     on FatTrees and the SDX benchmarks. Some ideas for improvement:

     - Easy: also account for setting tests field=X suceeded
     - Harder, but possibly much better: properly calculate the size of the
       pol for different field assignments. Don't traverse the policy
       repeatedly. Instead, write a size function that returns map from
       field assignments to sizes. *)
  let auto_order (pol : Probnetkat.policy) : unit =
    let open Probnetkat in
    (* Construct array of scores, where score starts at 0 for every field *)
    let count_arr = Array.init num_fields ~f:(fun _ -> 0) in
    let rec f_pred size (env, pred) = match pred with
      | True -> ()
      | False -> ()
      | Test (Probnetkat.Meta (id,_)) ->
        begin match Env.lookup env id with
        | (f, (Alias hv, false)) ->
          let f = to_enum f in
          let f' = to_enum (of_hv hv) in
          count_arr.(f) <- count_arr.(f) + size;
          count_arr.(f') <- count_arr.(f') + size
        | (f,_) ->
          let f = to_enum f in
          count_arr.(f) <- count_arr.(f) + size
        end
      | Test hv ->
        let f = to_enum (of_hv hv) in
        count_arr.(f) <- count_arr.(f) + size
      | Or (a, b) -> f_pred size (env, a); f_pred size (env, b)
      | And (a, b) -> f_pred size (env, a); f_pred size (env, b)
      | Neg a -> f_pred size (env, a) in
    let rec f_seq' pol lst env k = match pol with
      | Mod _ -> k (1, lst)
      | Filter a -> k (1, (env, a) :: lst)
      | Seq (p, q) ->
        f_seq' p lst env (fun (m, lst) ->
          f_seq' q lst env (fun (n, lst) ->
            k (m * n, lst)))
      | Union _ -> k (f_union pol env, lst)
      | Let { id; init; mut; body=p } ->
        let env = Env.add env id init mut in
        f_seq' p lst env k
      | Star p -> k (f_union p env, lst)
      | Link (sw,pt,_,_) -> k (1, (env, Test (Switch sw)) :: (env, Test (Location (Physical pt))) :: lst)
      | VLink (sw,pt,_,_) -> k (1, (env, Test (VSwitch sw)) :: (env, Test (VPort pt)) :: lst)
      | Dup -> k (1, lst)
    and f_seq pol env : int =
      let (size, preds) = f_seq' pol [] env (fun x -> x) in
      List.iter preds ~f:(f_pred size);
      size
    and f_union' pol lst env k = match pol with
      | Mod _ -> (1, lst)
      | Filter a -> (1, (env, a) :: lst)
      | Union (p, q) ->
        f_union' p lst env (fun (m, lst) ->
          f_union' q lst env (fun (n, lst) ->
            k (m + n, lst)))
      | Seq _ -> k (f_seq pol env, lst)
      | Let { id; init; mut; body=p } ->
        let env = Env.add env id init mut in
        k (f_seq p env, lst)
      | Star p -> f_union' p lst env k
      | Link (sw,pt,_,_) -> k (1, (env, Test (Switch sw)) :: (env, Test (Location (Physical pt))) :: lst)
      | VLink (sw,pt,_,_) -> k (1, (env, Test (VSwitch sw)) :: (env, Test (VPort pt)) :: lst)
      | Dup -> k (1, lst)
    and f_union pol env : int =
      let (size, preds) = f_union' pol [] env (fun x -> x) in
      List.iter preds ~f:(f_pred size);
      size
    in
    let _ = f_seq pol Env.empty in
    Array.foldi count_arr ~init:[] ~f:(fun i acc n -> ((Obj.magic i, n) :: acc))
    |> List.stable_sort ~cmp:(fun (_, x) (_, y) -> Int.compare x y)
    |> List.rev (* SJS: do NOT remove & reverse order! Want stable sort *)
    |> List.map ~f:fst
    |> set_order *)

end

module Value = struct
  include Int
  let subset_eq = equal
end



module Action = struct
  include Field.Map

  let compare = compare_direct Value.compare
  let one = empty
  let hash_fold_t = Map.hash_fold_direct Field.hash_fold_t

  let prod x y =
    (* Favor modifications to the right *)
    merge x y ~f:(fun ~key m ->
      match m with | `Both(_, v) | `Left v | `Right v -> Some(v))

  let sum x y = failwith "multicast not implemented!"

  let to_hvs = to_alist ~key_order:`Increasing

  let to_string (t : Value.t t) : string =
    let s = to_alist t
      |> List.map ~f:(fun (f,v) ->
          sprintf "%s := %s" (Field.to_string f) (Value.to_string v))
      |> String.concat ~sep:", "
    in "[" ^ s ^ "]"
end



module ActionDist = struct

  module T = Dist.Make(struct
    type t = Value.t Action.t [@@deriving sexp, eq, hash]
    let to_string = Action.to_string
    let compare = Action.compare
  end)

  include T

  let zero = T.empty
  let is_zero = T.is_empty

  let one = T.dirac Action.one
  let is_one d = match Map.find d Action.one with
    | None -> false
    | Some p when not Prob.(equal p one) -> false
    | Some _ -> Map.length d = 1

  let sum = T.sum

  let prod = T.prod_with ~f:Action.prod

  let negate t : t =
    (* This implements negation for the [zero] and [one] actions. Any
       non-[zero] action will be mapped to [zero] by this function. *)
    if is_zero t then one else zero
end


(** symbolic packets *)
module Packet = struct
  type nomval =
    | Const of Value.t
    | Atom (** An atom in the sense of nominal sets. Some fixed that value that is different
               from all constants. To a first approximation, a sort of wildcard, but it ranges
               only over values that do not appear as constants.
            *)
    [@@deriving compare, sexp]

  type t = nomval Field.Map.t
  (** Symbolic packet. Represents a set of concrete packets { π }.

      f |-> Const v  means π.f = v
      f |-> Atom     means π.f \in { values not appearing as f-values }
      f |-> ⊥        means π.f can have any value

      In particular, the empty map represents the set of all packets, and a map
      that associates a constant with every field represents a singleton set.
  *)

  let empty = Field.Map.empty

  let modify (pk : t) (f : Field.t) (v : nomval) : t =
    Map.add pk ~key:f ~data:v

  let apply (pk : t) (action : Value.t Action.t) : t =
    Field.Map.merge pk action ~f:(fun ~key:_ -> function
      | `Left v -> Some v
      | `Right v | `Both (_,v) -> Some (Const v))

(*   let pp fmt pk =
    Format.fprintf fmt "@[";
    if Map.is_empty pk then Format.fprintf fmt "*@ " else
    Map.iteri pk ~f:(fun ~key ~data -> Format.fprintf fmt "@[%s=%d@]@ " key data);
    Format.fprintf fmt "@]";
    () *)
end




module Fdd = struct

  include Vlr.Make
          (Field)
          (Value)
          (ActionDist)
  open Probnetkat

  type action = Value.t Action.t

  let allocate_fields (pol : string policy)
    : Field.t policy * Field.t String.Map.t =
    let tbl : (string, Field.t) Hashtbl.t = String.Table.create () in
    let next = ref 0 in
    let do_field env (f : string) : Field.t =
      match Field.Env.lookup env f with
      | (field, _) -> field
      | exception Not_found -> String.Table.find_or_add tbl f ~default:(fun () ->
        let open Field in
        let field = match !next with
          | 0 -> F0
          | 1 -> F1
          | 2 -> F2
          | 3 -> F3
          | 4 -> F4
          | _ -> failwith "too many fields! (only up to 5 supported)"
        in incr next; field)
    in
    let rec do_pol env (p : string policy) : Field.t policy =
      match p with
      | Filter pred ->
        Filter (do_pred env pred)
      | Modify (f,v) ->
        Modify (do_field env f, v)
      | Seq (p, q) ->
        Seq (do_pol env p, do_pol env q)
      | Ite (a, p, q) ->
        Ite (do_pred env a, do_pol env p, do_pol env q)
      | While (a, p) ->
        While (do_pred env a, do_pol env p)
      | Choice dist ->
        Choice (Util.map_fst dist ~f:(do_pol env))
      | Let { id; init; mut; body; } ->
        let init = match init with
          | Alias f -> Alias (do_field env f)
          | Const v -> Const v
        in
        let env = Field.Env.add env id init mut in
        let (id,_) = Field.Env.lookup env id in
        let body = do_pol env body in
        Let { id; init; mut; body; }
    and do_pred env (p : string pred) : Field.t pred =
      match p with
      | True -> True
      | False -> False
      | Test (f, v) -> Test (do_field env f, v)
      | And (p, q) -> And (do_pred env p, do_pred env q)
      | Or (p, q) -> Or (do_pred env p, do_pred env q)
      | Neg p -> Neg (do_pred env p)
    in
    let pol = do_pol Field.Env.empty pol in
    let field_map = String.(Map.of_alist_exn (Table.to_alist tbl)) in
    (pol, field_map)

  let of_test hv =
    atom hv ActionDist.one ActionDist.zero

  let of_mod (f,v) =
    const (ActionDist.dirac (Action.singleton f v))

  let negate fdd =
    map_r fdd ~f:ActionDist.negate

  let rec of_pred p =
    match p with
    | True      -> id
    | False     -> drop
    | Test(hv)  -> of_test hv
    | And(p, q) -> prod (of_pred p) (of_pred q)
    | Or (p, q) -> sum (of_pred p) (of_pred q)
    | Neg(q)    -> negate (of_pred q)

  let seq_tbl = BinTbl.create ~size:1000 ()

  let clear_cache ~preserve = begin
    BinTbl.clear seq_tbl;
    clear_cache preserve;
  end

  let seq t u =
    match unget u with
    | Leaf _ -> prod t u (* This is an optimization. If [u] is an
                            [Action.Par.t], then it will compose with [t]
                            regardless of however [t] modifies packets. None
                            of the decision variables in [u] need to be
                            removed because there are none. *)
    | Branch _ ->
      dp_map t
        ~f:(fun dist ->
          List.map (ActionDist.to_alist dist) ~f:(fun (action, prob) ->
            restrict_map (Action.to_hvs action) u ~f:(fun leaf ->
              ActionDist.scale leaf ~scalar:prob))
          |> List.fold ~init:drop ~f:sum
        )
        ~g:(fun v t f -> cond v t f)
        ~find_or_add:(fun t -> BinTbl.find_or_add seq_tbl (t,u))

  let union t u = sum t u

  let big_union fdds = List.fold ~init:drop ~f:union fdds

  let pypath = "."
  let py = Lymp.init ~exec:"python3" pypath
  let pyiterate = Lymp.get_module py "probnetkat"

  (* while a do p == (a; p)*; ¬a == X
     Thus  ¬A + APX = X.
     Thus (I - AP) X = ¬A
  *)
  let iterate a p =
(*     let pyscript = Findlib.package_directory "probnetkat"
    let (inch, outch) = Unix.open_process "python3" in *)
    failwith "todo"

  (** Erases (all matches on) meta field. No need to erase modifications. *)
  let erase t meta_field init =
    match init with
    | Const v ->
      restrict [(meta_field,v)] t
    | Alias alias ->
      fold t ~f:const ~g:(fun (field,v) tru fls ->
        if field = meta_field then
          cond (alias, v) tru fls
        else
          cond (field,v) tru fls)

  let rec of_pol_k p k =
    let open Probnetkat in
    match p with
    | Filter p ->
      k (of_pred p)
    | Modify m ->
      k (of_mod  m)
    | Seq (p, q) ->
      of_pol_k p (fun p' ->
        if equal p' drop then
          k drop
        else
          of_pol_k q (fun q' -> k (seq p' q')))
    | Ite (a, p, q) ->
      let a = of_pred a in
      if equal a id then
        of_pol_k p k
      else if equal a drop then
        of_pol_k q k
      else
        of_pol_k p (fun p ->
          of_pol_k q (fun q ->
            k @@ union (prod a p) (prod (negate a) q)
          )
        )
    | While (a, p) ->
      of_pol_k p (fun p ->
        k @@ iterate (of_pred a) p
      )
    | Choice dist ->
      List.map dist ~f:(fun (p, prob) ->
        of_pol_k p (map_r ~f:(ActionDist.scale ~scalar:prob))
      )
      |> big_union
      |> k
    | Let { id=field; init; mut; body=p } ->
      of_pol_k p (fun p' -> k (erase p' field init))

  and of_symbolic_pol p = of_pol_k p ident

  let of_pol p =
    let (p, map) = allocate_fields p in
    of_symbolic_pol p

  let to_maplets fdd : (Packet.t * action * Prob.t) list =
    let rec of_node fdd pk acc =
      match unget fdd with
      | Leaf r ->
        of_leaf r pk acc
      | Branch ((f,v), tru, fls) ->
        of_node tru Packet.(modify pk f (Const v)) acc
        |> of_node fls Packet.(modify pk f Atom)
    and of_leaf dist pk acc =
      ActionDist.to_alist dist
      |> List.fold ~init:acc ~f:(fun acc (act, prob) -> (pk, act, prob) :: acc)
    in
    of_node fdd Packet.empty []

end



(** domain of an Fdd *)
module Domain = struct
  module Valset = Set.Make(struct type t = Packet.nomval [@@deriving sexp, compare] end)
  type t = Valset.t Field.Map.t


  let merge d1 d2 : t =
    Map.merge d1 d2 ~f:(fun ~key -> function
      | `Left s | `Right s -> Some s
      | `Both (l,r) -> Some (Set.union l r))

  let of_fdd (fdd : Fdd.t) : t =
    let rec for_fdd dom fdd =
      match Fdd.unget fdd with
      | Leaf r ->
        for_leaf dom r
      | Branch ((field,_),_,_) ->
        let (vs, residuals, all_false) = for_field field fdd [] [] in
        let vs =
          List.map vs ~f:(fun v -> Packet.Const v)
          |> (fun vs -> if Fdd.(equal drop all_false) then vs else Atom::vs)
          |> Valset.of_list
        in
        let dom = Map.update dom field ~f:(function
          | None -> vs
          | Some vs' -> Set.union vs vs')
        in
        List.fold residuals ~init:dom ~f:for_fdd

    (** returns list of values appearing in tests with field [f] in [fdd], and
        residual trees below f-tests, and the all-false branch with respect to
        field f. *)
    and for_field f fdd vs residual =
      match Fdd.unget fdd with
      | Branch ((f',v), tru, fls) when f' = f ->
        for_field f fls (v::vs) (tru::residual)
      | Branch _ | Leaf _ ->
        (vs, fdd::residual, fdd)

    and for_leaf dom dist =
      ActionDist.support dist
      |> List.fold ~init:dom ~f:for_action

    and for_action dom action =
      Action.to_alist action
      |> Util.map_snd ~f:(fun v -> Valset.singleton (Const v))
      |> Field.Map.of_alist_exn
      |> merge dom

    in
    for_fdd Field.Map.empty fdd

  let size (dom : t) : int =
    Map.fold dom ~init:1 ~f:(fun ~key ~data:vs acc -> acc * (Valset.length vs))

end






(** packet coding *)
type 'domain_witness hyperpoint = int list
type 'domain_witness codepoint = int
type 'domain_witness index = { i : int }  [@@unboxed]
type 'domain_witness index0 = { i : int } [@@unboxed]

module type DOM = sig
  val domain : Domain.t
end

module type S = sig
  type domain_witness

  (** Encoding of packet in n dimensional space.
      More precisely, a packet is encoded as a point in a hypercube, with the
      coordinates being of type int.
      If [dimension] = {k1, ..., kn}, then the hypercube is given by
        {0, ..., k1} x ... x {0, ..., kn}.
      The points within this cube are represented as lists, rather than tuples,
      because n is not known at compile time.
  *)
  module rec Hyperpoint : sig
    type t = domain_witness hyperpoint
    val dimension : int list
    val to_codepoint : t -> Codepoint.t
    val of_codepoint : Codepoint.t -> t
    val to_pk : t -> Packet.t
    val of_pk : Packet.t -> t
  end

  (** Encoding of packets as integers >= 0, i.e. points in single dimensional space. *)
  and Codepoint : sig
    type t = domain_witness codepoint
    val max : t
    val to_hyperpoint : t -> Hyperpoint.t
    val of_hyperpoint : Hyperpoint.t -> t
    val to_pk : t -> Packet.t
    val of_pk : Packet.t -> t
    val to_index : t -> Index.t
    val of_index : Index.t -> t
    val to_index0 : t -> Index0.t
    val of_index0 : Index0.t -> t
  end

  (** Encoding of packets as strictly positive integers, i.e. 1-based matrix indices. *)
  and Index : sig
    type t = domain_witness index
    val max : t
    val of_pk : Packet.t -> t
    val to_pk : t -> Packet.t
    (* val test : Field.t -> Packet.nomval -> t -> bool *)
    val modify : Field.t -> Packet.nomval -> t -> t
    (* val test' : Field.t -> Packet.nomval -> int -> bool *)
    val modify' : Field.t -> Packet.nomval -> int -> int
(*     val pp : Format.formatter -> t -> unit
    val pp' : Format.formatter -> int -> unit *)
  end

  (** Encoding of packets as positive integers (including 0), i.e. 0-based matrix indices. *)
  and Index0 : sig
    type t = domain_witness index0
    val max : t
    val of_pk : Packet.t -> t
    val to_pk : t -> Packet.t
    (* val test : Field.t -> Packet.nomval -> t -> bool *)
    val modify : Field.t -> Packet.nomval -> t -> t
    (* val test' : Field.t -> Packet.nomval -> int -> bool *)
    val modify' : Field.t -> Packet.nomval -> int -> int
(*     val pp : Format.formatter -> t -> unit
    val pp' : Format.formatter -> int -> unit *)
  end
end

module Make(D : DOM) : S = struct

  let domain : (Field.t * Packet.nomval list) list =
    Map.to_alist (Map.map D.domain ~f:Set.to_list)

  type domain_witness

  module Hyperpoint = struct
    type t = domain_witness hyperpoint

    let dimension =
      List.map domain ~f:(fun (_,vs) -> List.length vs)

    let injection : (Field.t * (Packet.nomval -> int)) list =
      List.Assoc.map domain ~f:(fun vs ->
        List.mapi vs ~f:(fun i v -> (v, i))
        |> Map.Poly.of_alist_exn
        |> Map.Poly.find_exn)

    let ejection : (Field.t * (int -> Packet.nomval)) list =
      List.Assoc.map domain ~f:List.to_array
      |> List.Assoc.map ~f:(fun inj v -> inj.(v))


    let to_codepoint t =
      List.fold2_exn t dimension ~init:0 ~f:(fun cp v n -> v + n * cp)

    let of_codepoint cp =
      List.fold_right dimension ~init:(cp,[]) ~f:(fun n (cp, hp) ->
        let (cp, v) = Int.(cp /% n, cp % n) in
        (cp, v::hp))
      |> snd

    let to_pk t =
      List.fold2_exn t ejection ~init:Field.Map.empty ~f:(fun pk v (f, veject) ->
        Field.Map.add pk ~key:f ~data:(veject v))


    let of_pk pk =
      List.map injection ~f:(fun (f, vinj) -> vinj (Field.Map.find_exn pk f))
  end

  module Codepoint = struct
    type t = domain_witness codepoint
    let to_hyperpoint = Hyperpoint.of_codepoint
    let of_hyperpoint = Hyperpoint.to_codepoint
    let to_pk = Fn.compose Hyperpoint.to_pk to_hyperpoint
    let of_pk = Fn.compose of_hyperpoint Hyperpoint.of_pk
    let max = (List.fold ~init:1 ~f:( * ) Hyperpoint.dimension) - 1
    let to_index cp : domain_witness index = { i = cp + 1  }
    let of_index (idx : domain_witness index) = idx.i - 1
    let to_index0 cp : domain_witness index0 = { i = cp }
    let of_index0 (idx : domain_witness index0) = idx.i
  end

  module Index = struct
    type t = domain_witness index
    let of_pk = Fn.compose Codepoint.to_index Codepoint.of_pk
    let to_pk = Fn.compose Codepoint.to_pk Codepoint.of_index
    let max = Codepoint.(to_index max)
    (* let test f n t = Packet.test f n (to_pk t) *)
    let modify f n t = of_pk (Packet.modify (to_pk t) f n)
    (* let test' f n i = test f n { i = i } *)
    let modify' f n i = (modify f n { i = i }).i
(*     let pp fmt t = Packet.pp fmt (to_pk t)
    let pp' fmt i = Packet.pp fmt (to_pk { i = i }) *)
  end

  module Index0 = struct
    type t = domain_witness index0
    let of_pk = Fn.compose Codepoint.to_index0 Codepoint.of_pk
    let to_pk = Fn.compose Codepoint.to_pk Codepoint.of_index0
    let max = Codepoint.(to_index0 max)
    (* let test f n t = Packet.test f n (to_pk t) *)
    let modify f n t = of_pk (Packet.modify (to_pk t) f n)
    (* let test' f n i = test f n { i = i } *)
    let modify' f n i = (modify f n { i = i }).i
(*     let pp fmt t = Packet.pp fmt (to_pk t)
    let pp' fmt i = Packet.pp fmt (to_pk { i = i }) *)
  end

end







(** matrix representation of Fdd *)
module Matrix = struct
  type t = {
    dom : Domain.t;
    matrix : Sparse.mat;
    conversion : (module S);
  }

  let packet_variants pk dom : Packet.t list =
    failwith "not implemented"

  let maplet_to_matrix_entries dom (conversion : (module S)) (pk, act, prob)
    : (int * int * Prob.t) list =
    let module Conv = (val conversion : S) in
    packet_variants pk dom
    |> List.map ~f:(fun pk ->
      let pk' = Packet.apply pk act in
      ((Conv.Index.of_pk pk).i, (Conv.Index.of_pk pk').i, prob)
    )

  let of_fdd fdd =
    let dom = Domain.of_fdd fdd in
    let module Conversion = Make(struct let domain = dom end) in
    let conversion = (module Conversion : S) in
    let n = Domain.size dom in
    let matrix = Sparse.zeros n n in
    Fdd.to_maplets fdd
    |> List.concat_map ~f:(maplet_to_matrix_entries dom conversion)
    |> List.iter ~f:(fun (i,j,v) -> Sparse.set matrix i j Prob.(to_float v));
    { dom; matrix; conversion }

end
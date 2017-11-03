open Core
open ProbNetKAT
open ProbNetKAT_Packet_Repr
open ProbNetKAT.Syntax.Dumb

module Mc = ProbNetKAT_Mc

let fprintf = Format.fprintf
let fmt = Format.std_formatter

module Dense = Owl.Dense.Matrix.D
module Sparse = Owl.Sparse.Matrix.D

let time f =
  let t1 = Unix.gettimeofday () in
  let r = f () in
  let t2 = Unix.gettimeofday () in
  (t2 -. t1, r)

let print_time fmt time =
  fprintf fmt "time: %.4f\n" time

let identity = fun x -> x

let rec test_filter test_fn (query:policy) i =
  match query.p with
  | Skip -> true
  | Drop -> false
  | Test (f, n) -> test_fn f n i
  | Neg a -> not (test_filter test_fn a i)
  | Or (a1, a2) ->
    test_filter test_fn a1 i || test_filter test_fn a2 i
  | Seq (a1, a2) ->
    test_filter test_fn a1 i && test_filter test_fn a2 i
  | _ -> failwith "Invalid query"

let print_dom_size fmt n dom = begin
  fprintf fmt "size of state space = %s" (Int.to_string_hum n);
  if Map.length dom > 1 then
    Map.data dom
    |> List.map ~f:(fun vs -> Int.to_string (Set.length vs + 1))
    |> String.concat ~sep:" x "
    |> fprintf fmt " (%s)";
  fprintf fmt "\n\n%!";
end

let compare ?(print_query=true) ?(print_dense=false) ?(lbl=true)
      ?(transpose=false) ?(fmt=fmt) ?(debug=false)
      ?(row_query=skip) ?(col_query=skip) ?(reset_fn=skip) p1 p2 =
  fprintf fmt "\n========================= EIGEN ==========================\n\n%!";
  fprintf fmt "policy #1 = %a\n\n%!" pp_policy p1;
  fprintf fmt "policy #2 = %a\n\n%!" pp_policy p2;
  fprintf fmt "reset tmp fields = %a\n\n%!" pp_policy reset_fn;
  let p1 = p1 >> reset_fn in
  let p2 = p2 >> reset_fn in
  let dom = domain (p1 >> p2) in (* merge fields in domain *)
  let module Repr = ProbNetKAT_Packet_Repr.Make(struct let domain = dom end) in
  let n = Repr.Index0.max.i + 1 in
  print_dom_size fmt n dom;
  let module Mc = ProbNetKAT_Mc.MakeOwl(Repr) in
  List.fold [p1; p2] ~init:[] ~f:(fun acc p ->
  let (t, mc) = time (fun () -> Mc.of_pol ~debug p) in
  let dense_mc = (if transpose then Sparse.transpose else ident) mc |>
                   Sparse.to_dense in
  let rows = Dense.filteri_rows (fun i _ -> test_filter Repr.Index.test' row_query i) dense_mc in
  let cols = Dense.filteri_cols (fun i _ -> test_filter Repr.Index.test' col_query i) dense_mc in
  let fd_mc = Dense.rows dense_mc (Array.map ~f:(fun i -> i - 1) rows) in
  let fd_mc = Dense.cols fd_mc (Array.map ~f:(fun i -> i - 1) cols) in
  (* let fd_mc = Dense.cols fd_mc cols in *)
  let print_mat ?(row_map=identity) ?(col_map=identity) ?(fmt=fmt) ?(head=true)=
    fprintf fmt "@[MATRIX:@\n%a@\n@]@."
      (if not lbl then Owl_pretty.pp_fmat else
         Owl_pretty.pp_labeled_fmat
           ~pp_left:(Some (fun fmt i -> fprintf fmt "%a|" Repr.Index.pp' (row_map i)))
           ~pp_head:(if head then (Some (fun fmt i -> fprintf fmt "%a|" Repr.Index.pp' (col_map i))) else None)
           ~pp_foot:None
           ~pp_right:None ()) in

  if print_query then begin
    fprintf fmt "\n============ Matrix for queried input/output =========\n\n%!";
    print_mat ~row_map:(fun x -> Array.nget rows (x-1)) ~col_map:(fun x -> Array.nget cols (x-1)) ~fmt fd_mc;
  end;
  if print_dense then begin
    fprintf fmt "\n============== Complete matrix ==========\n\n%!";
    print_mat ~fmt ~head:false dense_mc;
  end;
  print_time fmt t;
  (dense_mc, fd_mc) :: acc)
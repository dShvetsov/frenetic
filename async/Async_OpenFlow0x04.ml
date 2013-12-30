open Core.Std

module Platform = Async_OpenFlow_Platform
module Header = OpenFlow_Header
module M = OpenFlow0x04.Message

module Message : Platform.Message with type t = (Header.xid * M.t) = struct

  type t = (Header.xid * M.t) sexp_opaque with sexp

  let header_of (xid, m)= M.header_of xid m
  let parse hdr buf = M.parse hdr (Cstruct.to_string buf)
  let marshal (xid, m) buf = M.marshal_body m buf
  let to_string _ = "we do not have an implementation of to_string for 1.3"

  let marshal' msg =
    let hdr = header_of msg in
    let body_len = hdr.Header.length - Header.size in
    let body_buf = Cstruct.create body_len in
    marshal msg body_buf;
    (hdr, body_buf)
end

include Async_OpenFlow_Message.MakeSerializers (Message)

module Controller = struct
  open Async.Std

  module ChunkController = Async_OpenFlowChunk.Controller
  module Switch_id = ChunkController.Switch_id

  module SwitchTable = Map.Make(Switch_id)

  exception Handshake of Switch_id.t * string

  type t = {
    sub : ChunkController.t;
  }

  let openflow0x04 _ evt =
    match evt with
      | `Message (s_id, (hdr, bits)) ->
        return (Some(`Message (s_id, Message.parse hdr bits)))
      | `Connect e -> return (Some(`Connect e))
      | `Disconnect e -> return (Some(`Disconnect e))

  let create ?max_pending_connections ?verbose ?log_disconnects ?buffer_age_limit ~port =
    ChunkController.create ?max_pending_connections ?verbose ?log_disconnects
      ?buffer_age_limit ~port
    >>| function t -> { sub = t }

  let listen t =
    let open Async_OpenFlow_Platform.Trans in
    let open ChunkController in
    let stages =
      (local (fun t -> t.sub)
        (handshake 0x04 >=> echo))
      >=> openflow0x04 in
    run stages t (listen t.sub)

  let close t = ChunkController.close t.sub
  let has_switch_id t = ChunkController.has_switch_id t.sub
  let send t s_id msg = ChunkController.send t.sub s_id (Message.marshal' msg)
  let send_to_all t msg = ChunkController.send_to_all t.sub (Message.marshal' msg)
  let client_addr_port t = ChunkController.client_addr_port t.sub
  let listening_port t = ChunkController.listening_port t.sub
end

open! Core

let path ~dir instrument stream date =
  Store.path (Store.create dir) Norm instrument stream date
;;

let digest = Bin_prot.Shape.eval_to_digest_string Event.Stable.V1.bin_shape_t

(* Append only. Never remove or reorder an entry: recordings carrying it exist. *)
let compatible_digests =
  [ (* Event.Stable.V1 with [Funding_v2] appended, for funding without an exchange
       timestamp. *)
    "cdf98830f211bb2d1384927d19dab635"
  ; (* Event.Stable.V1 with eleven venues, Hyperliquid to Cme. *)
    "2f7f1bcba79db3ddd1b04d266342a8af"
  ; (* Event.Stable.V1 before the venue extension: Hyperliquid, Binance, Bybit. New
       constructors were appended, so the old encoding is a subset of the new one. *)
    "4cf56dfbcb69fbab68b38db7a2944d7b"
  ]
;;

let accept = List.filter compatible_digests ~f:(fun d -> not (String.equal d digest))

module Key = struct
  type t = Instrument.t * Stream.t [@@deriving compare, equal, hash, sexp_of]
end

module Writer = struct
  type t =
    { dir : string
    ; flush_interval : Time_ns.Span.t option
    ; flush_bytes : int option
    ; writers : (Key.t, Event.t Framed.Writer.t) Hashtbl.t
    ; snapshot_interval : Time_ns.Span.t option
    ; snapshots :
        ( Instrument.t
          , Snapshot_index.Builder.t * Snapshot_index.Entry.t Framed.Writer.t )
          Hashtbl.t
    }

  let create ?flush_interval ?flush_bytes ?snapshot_interval ~dir () =
    Option.iter snapshot_interval ~f:(fun interval ->
      ignore (Snapshot_index.Builder.create ~interval : Snapshot_index.Builder.t));
    { dir
    ; flush_interval
    ; flush_bytes
    ; writers = Hashtbl.create (module Key)
    ; snapshot_interval
    ; snapshots = Hashtbl.create (module Instrument)
    }
  ;;

  let snapshot t (u : L2_update.t) =
    match t.snapshot_interval with
    | None -> ()
    | Some interval ->
      let builder, writer =
        Hashtbl.find_or_add t.snapshots u.instrument ~default:(fun () ->
          ( Snapshot_index.Builder.create ~interval
          , Framed.Writer.create
              ?flush_interval:t.flush_interval
              ?flush_bytes:t.flush_bytes
              ~digest:Snapshot_index.digest
              Snapshot_index.Entry.bin_writer_t
              ~path_for_date:(Snapshot_index.path ~dir:t.dir u.instrument)
              () ))
      in
      Option.iter (Snapshot_index.Builder.observe builder u) ~f:(fun entry ->
        Framed.Writer.append writer entry ~time:entry.at)
  ;;

  let writer t ((instrument, stream) as key) =
    Hashtbl.find_or_add t.writers key ~default:(fun () ->
      Framed.Writer.create
        ?flush_interval:t.flush_interval
        ?flush_bytes:t.flush_bytes
        ~digest
        ~accept
        Event.bin_writer_t
        ~path_for_date:(path ~dir:t.dir instrument stream)
        ())
  ;;

  let append t event =
    (match (event : Event.t) with
     | L2 u -> snapshot t u
     | Trade _ | Bbo _ | Funding _ -> ());
    Framed.Writer.append
      (writer t (Event.instrument event, Event.stream event))
      event
      ~time:(Event.recv_ts event)
  ;;

  let all t ~f ~g =
    let open Async in
    let%map () = Deferred.List.iter ~how:`Parallel (Hashtbl.data t.writers) ~f
    and () =
      Deferred.List.iter ~how:`Parallel (Hashtbl.data t.snapshots) ~f:(fun (_, w) -> g w)
    in
    ()
  ;;

  let flush t = all t ~f:Framed.Writer.flush ~g:Framed.Writer.flush
  let close t = all t ~f:Framed.Writer.close ~g:Framed.Writer.close

  let files t =
    Hashtbl.data t.writers
    |> List.concat_map ~f:Framed.Writer.files
    |> List.sort ~compare:String.compare
  ;;

  let snapshot_files t =
    Hashtbl.data t.snapshots
    |> List.concat_map ~f:(fun (_, w) -> Framed.Writer.files w)
    |> List.sort ~compare:String.compare
  ;;
end

let read_file path = Framed.read_file ~digest ~accept Event.bin_reader_t path
let load_file path = Framed.load_file ~digest ~accept Event.bin_reader_t path

let read_merged paths =
  Merge.sorted
    (List.map paths ~f:(fun path -> fst (read_file path)))
    ~compare:Event.compare_by_recv_ts
;;

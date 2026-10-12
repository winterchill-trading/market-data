open! Core

let path ~dir instrument stream date =
  Store.path (Store.create dir) Norm instrument stream date
;;

module Key = struct
  type t = Instrument.t * Stream.t [@@deriving compare, equal, hash, sexp_of]
end

module Writer = struct
  type t =
    { dir : string
    ; flush_interval : Time_ns.Span.t option
    ; flush_bytes : int option
    ; writers : (Key.t, Event.t Framed.Writer.t) Hashtbl.t
    }

  let create ?flush_interval ?flush_bytes ~dir () =
    { dir; flush_interval; flush_bytes; writers = Hashtbl.create (module Key) }
  ;;

  let writer t ((instrument, stream) as key) =
    Hashtbl.find_or_add t.writers key ~default:(fun () ->
      Framed.Writer.create
        ?flush_interval:t.flush_interval
        ?flush_bytes:t.flush_bytes
        Event.bin_writer_t
        ~path_for_date:(path ~dir:t.dir instrument stream)
        ())
  ;;

  let append t event =
    Framed.Writer.append
      (writer t (Event.instrument event, Event.stream event))
      event
      ~time:(Event.recv_ts event)
  ;;

  let all t ~f = Async.Deferred.List.iter ~how:`Parallel (Hashtbl.data t.writers) ~f
  let flush t = all t ~f:Framed.Writer.flush
  let close t = all t ~f:Framed.Writer.close

  let files t =
    Hashtbl.data t.writers
    |> List.concat_map ~f:Framed.Writer.files
    |> List.sort ~compare:String.compare
  ;;
end

let read_file path = Framed.read_file Event.bin_reader_t path
let load_file path = Framed.load_file Event.bin_reader_t path

let read_merged paths =
  Merge.sorted
    (List.map paths ~f:(fun path -> fst (read_file path)))
    ~compare:Event.compare_by_recv_ts
;;

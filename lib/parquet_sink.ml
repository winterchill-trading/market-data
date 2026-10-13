open! Core
open! Async

type 'a batch =
  { date : Date.t
  ; rows : 'a list
  ; count : int
  }

type 'a message =
  | Rows of 'a batch
  | End_of_day

type 'a t =
  { schema : 'a Parquet.Schema.t
  ; direct : ('a Parquet.Writer.t -> 'a -> unit) option
  ; dir : string
  ; instrument : Instrument.t
  ; kind : Parquet_kind.t
  ; row_group_rows : int
  ; compression : [ `None | `Zstd ]
  ; time_source : Time_source.t
  ; max_pending_rows : int
  ; mutable buffer : 'a list (** most recent first *)
  ; mutable buffer_count : int
  ; mutable buffer_date : Date.t option (** day of the rows in [buffer] *)
  ; mutable day : Date.t option (** day of the last row added *)
  ; mutable pending : int
  ; mutable dropped : int
  ; mutable closed : bool
  ; mutable files : string list (** most recent first *)
  ; batches : 'a message Pipe.Writer.t
  ; writer_done : unit Deferred.t
  }

(* [<date>.parquet], or the first free [<date>.<n>.parquet]. *)
let free_path ~dir instrument kind date =
  let base = Parquet_kind.path ~dir instrument kind date in
  let candidate n =
    if n = 0
    then base
    else (
      let stem = String.chop_suffix_exn base ~suffix:".parquet" in
      sprintf "%s.%d.parquet" stem n)
  in
  let rec go n =
    let path = candidate n in
    match%bind Sys.file_exists_exn path with
    | true -> go (n + 1)
    | false -> return path
  in
  go 0
;;

let writer_loop t reader =
  let file = ref None in
  let close_file () =
    match !file with
    | None -> return ()
    | Some (_, f) ->
      file := None;
      let%map () = Parquet_file.close f in
      t.files <- Parquet_file.path f :: t.files
  in
  let file_for date =
    match !file with
    | Some (d, f) when Date.equal d date -> return f
    | _ ->
      let%bind () = close_file () in
      let%bind path = free_path ~dir:t.dir t.instrument t.kind date in
      let%map f =
        Parquet_file.create
          ~compression:t.compression
          ?direct:t.direct
          t.schema
          ~row_group_rows:t.row_group_rows
          path
      in
      file := Some (date, f);
      f
  in
  let%bind () =
    Pipe.iter reader ~f:(function
      | End_of_day -> close_file ()
      | Rows batch ->
        let%bind f = file_for batch.date in
        let%map () = Parquet_file.add f (List.rev batch.rows) in
        t.pending <- t.pending - batch.count)
  in
  close_file ()
;;

let create
  ?(time_source = Time_source.wall_clock ())
  ?(compression = `Zstd)
  ?max_pending_rows
  ?direct
  schema
  ~dir
  instrument
  kind
  ~row_group_rows
  =
  if row_group_rows < 1
  then raise_s [%message "Parquet_sink.create: row_group_rows < 1" (row_group_rows : int)];
  let max_pending_rows = Option.value max_pending_rows ~default:(16 * row_group_rows) in
  let reader, batches = Pipe.create () in
  let writer_done = Ivar.create () in
  let t =
    { schema
    ; direct
    ; dir
    ; instrument
    ; kind
    ; row_group_rows
    ; compression
    ; time_source
    ; max_pending_rows
    ; buffer = []
    ; buffer_count = 0
    ; buffer_date = None
    ; day = None
    ; pending = 0
    ; dropped = 0
    ; closed = false
    ; files = []
    ; batches
    ; writer_done = Ivar.read writer_done
    }
  in
  don't_wait_for (writer_loop t reader >>| Ivar.fill_exn writer_done);
  t
;;

let hand_over t =
  match t.buffer_date with
  | None -> ()
  | Some date ->
    let batch = { date; rows = t.buffer; count = t.buffer_count } in
    t.buffer <- [];
    t.buffer_count <- 0;
    t.buffer_date <- None;
    if t.pending + batch.count > t.max_pending_rows
    then t.dropped <- t.dropped + batch.count
    else (
      t.pending <- t.pending + batch.count;
      Pipe.write_without_pushback t.batches (Rows batch))
;;

let add t row =
  if t.closed then raise_s [%message "Parquet_sink.add: closed"];
  let date = Store.date_of_time (Time_source.now t.time_source) in
  (match t.day with
   | Some d when not (Date.equal d date) ->
     hand_over t;
     Pipe.write_without_pushback t.batches End_of_day
   | _ -> ());
  t.day <- Some date;
  t.buffer_date <- Some date;
  t.buffer <- row :: t.buffer;
  t.buffer_count <- t.buffer_count + 1;
  if t.buffer_count >= t.row_group_rows then hand_over t
;;

let close t =
  if not t.closed
  then (
    t.closed <- true;
    hand_over t;
    Pipe.close t.batches);
  t.writer_done
;;

let files t = List.rev t.files
let dropped t = t.dropped
let pending t = t.pending

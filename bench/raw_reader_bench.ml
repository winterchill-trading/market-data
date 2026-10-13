open! Core
open! Async
open Market_data

let frame i =
  sprintf
    {|{"channel":"l2Book","data":{"coin":"BTC","time":%d,"levels":[[{"px":"60000.%d","sz":"1.25","n":3}],[{"px":"60001.%d","sz":"0.75","n":2}]]}}|}
    i
    (i % 10)
    (i % 10)
;;

let write ~dir ~minutes ~lines_per_minute ~streams =
  let start = Time_ns.of_string_with_utc_offset "2026-01-01T00:00:00Z" in
  Deferred.List.iter streams ~how:`Sequential ~f:(fun stream ->
    Deferred.List.iter (List.init minutes ~f:Fn.id) ~how:`Sequential ~f:(fun m ->
      let minute = Time_ns.add start (Time_ns.Span.of_int_sec (60 * m)) in
      let buf = Buffer.create (lines_per_minute * 200) in
      for i = 0 to lines_per_minute - 1 do
        let ts =
          Time_ns.add minute (Time_ns.Span.of_int_us (i * 60_000_000 / lines_per_minute))
        in
        Buffer.add_string
          buf
          (Time_ns.to_string_iso8601_basic ts ~zone:Time_float.Zone.utc);
        Buffer.add_char buf ' ';
        Buffer.add_string buf (frame i);
        Buffer.add_char buf '\n'
      done;
      let path =
        sprintf
          "%s/raw/hyperliquid/%s/BTC/2026/01/01/%02d-%02d.ndjson.zst"
          dir
          (Stream.to_string stream)
          (m / 60)
          (m % 60)
      in
      let%bind () = Unix.mkdir ~p:() (Filename.dirname path) in
      Writer.save path ~contents:(Zstd.compress ~level:3 (Buffer.contents buf))))
;;

let merge_only ~n =
  let inputs =
    List.init 3 ~f:(fun k -> Pipe.of_list (List.init n ~f:(fun i -> (3 * i) + k)))
  in
  let words0 = Gc.minor_words () in
  let t0 = Time_ns.now () in
  let%map count =
    Merge.sorted inputs ~compare:Int.compare
    |> Pipe.fold_without_pushback ~init:0 ~f:(fun n _ -> n + 1)
  in
  let secs = Time_ns.Span.to_sec (Time_ns.diff (Time_ns.now ()) t0) in
  printf
    "merge only: %d values in %.3fs: %.0f values/s, %.1f minor words per value\n"
    count
    secs
    (Float.of_int count /. secs)
    (Float.of_int (Gc.minor_words () - words0) /. Float.of_int count)
;;

let command =
  Command.async
    ~summary:"Lines per second through Raw_reader.read"
    (let%map_open.Command minutes =
       flag "-minutes" (optional_with_default 10 int) ~doc:"N minute files per stream"
     and lines_per_minute =
       flag "-lines" (optional_with_default 20_000 int) ~doc:"N lines per minute file"
     and merge =
       flag
         "-merge-only"
         no_arg
         ~doc:" time Merge.sorted over in-memory int pipes instead"
     in
     fun () ->
       if merge
       then merge_only ~n:(minutes * lines_per_minute)
       else (
         let streams = [ Stream.Trades; Bbo; L2 ] in
         let dir = Filename_unix.temp_dir "raw-reader-bench" "" in
         let%bind () = write ~dir ~minutes ~lines_per_minute ~streams in
         let words0 = Gc.minor_words () in
         let t0 = Time_ns.now () in
         let%bind count, bytes =
           Raw_reader.read
             ~data_dir:dir
             ~venue:Hyperliquid
             ~symbol:"BTC"
             ~start:(Time_ns.of_string_with_utc_offset "2026-01-01T00:00:00Z")
             ~stop:(Time_ns.of_string_with_utc_offset "2026-01-02T00:00:00Z")
             ()
           |> Pipe.fold_without_pushback ~init:(0, 0) ~f:(fun (n, b) item ->
             match (item : Raw_reader.Item.t) with
             | Frame { frame; _ } -> n + 1, b + String.length frame
             | Gap _ -> n + 1, b)
         in
         let secs = Time_ns.Span.to_sec (Time_ns.diff (Time_ns.now ()) t0) in
         printf
           "%d lines (%d MB of frames) in %.2fs: %.0f lines/s, %.1f minor words per line\n"
           count
           (bytes / 1_000_000)
           secs
           (Float.of_int count /. secs)
           (Float.of_int (Gc.minor_words () - words0) /. Float.of_int count);
         Unix.system_exn (sprintf "rm -rf %s" (Filename.quote dir))))
;;

let () = Command_unix.run command

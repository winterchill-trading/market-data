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

let command =
  Command.async
    ~summary:"Lines per second through Raw_reader.read"
    (let%map_open.Command minutes =
       flag "-minutes" (optional_with_default 10 int) ~doc:"N minute files per stream"
     and lines_per_minute =
       flag "-lines" (optional_with_default 20_000 int) ~doc:"N lines per minute file"
     in
     fun () ->
       let streams = [ Stream.Trades; Bbo; L2 ] in
       let dir = Filename_unix.temp_dir "raw-reader-bench" "" in
       let%bind () = write ~dir ~minutes ~lines_per_minute ~streams in
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
         "%d lines (%d MB of frames) in %.2fs: %.0f lines/s\n"
         count
         (bytes / 1_000_000)
         secs
         (Float.of_int count /. secs);
       Unix.system_exn (sprintf "rm -rf %s" (Filename.quote dir)))
;;

let () = Command_unix.run command

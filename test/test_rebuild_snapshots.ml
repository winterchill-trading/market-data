(* [Rebuild_norm] writes the same L2 snapshot index as the live writer. *)

open! Core
open! Async
open Market_data

(* A venue whose frames are sexps of [L2_update.t]. *)
module Sexp_l2 : Normalizer.S = struct
  type t = unit

  let venue = Venue.Binance
  let create () = ()

  let frame () ~recv_ts:_ payload =
    Or_error.try_with (fun () ->
      [ Event.L2 (L2_update.t_of_sexp (Sexp.of_string payload)) ])
  ;;

  let disconnect () = ()
end

let level price size : L2_update.Level.t =
  { price = Price.of_string price; size = Size.of_string size }
;;

(* A snapshot, then a delta every 15 seconds for five minutes. *)
let updates =
  let at ms kind ~bids ~asks : L2_update.t =
    { instrument = Sample.btc
    ; exch_ts = Sample.ts ms
    ; recv_ts = Sample.ts ms
    ; kind
    ; bids = List.map bids ~f:(fun (p, s) -> level p s)
    ; asks = List.map asks ~f:(fun (p, s) -> level p s)
    }
  in
  at 5 Snapshot ~bids:[ "99", "1"; "98", "2" ] ~asks:[ "101", "1"; "102", "2" ]
  :: List.map (List.range 1 21) ~f:(fun i ->
    let size = Int.to_string (i % 4) in
    at
      (i * 15_000)
      Delta
      ~bids:[ Int.to_string (99 - (i % 3)), size ]
      ~asks:[ Int.to_string (101 + (i % 5)), size ])
;;

let raw_line (u : L2_update.t) =
  sprintf
    "%s %s"
    (Time_ns.to_string_iso8601_basic u.recv_ts ~zone:Time_float.Zone.utc)
    (Sexp.to_string [%sexp (u : L2_update.t)])
;;

let minute_of (u : L2_update.t) =
  Time_ns.Span.(Time_ns.diff u.recv_ts (Sample.ts 0) // of_min 1.)
  |> Float.iround_down_exn
;;

let write_raw ~dir =
  let day = dir ^/ "raw/binance/l2/BTCUSDT/2026/01/01" in
  let%bind () = Unix.mkdir ~p:() day in
  List.group updates ~break:(fun a b -> minute_of a <> minute_of b)
  |> Deferred.List.iter ~how:`Sequential ~f:(fun minute ->
    let file = sprintf "00-%02d.ndjson" (minute_of (List.hd_exn minute)) in
    Writer.save
      (day ^/ file)
      ~contents:(String.concat (List.map minute ~f:(fun u -> raw_line u ^ "\n"))))
;;

let live ~dir =
  let w =
    Event_log.Writer.create
      ~snapshot_interval:Rebuild_norm.default_snapshot_interval
      ~dir
      ()
  in
  List.iter updates ~f:(fun u -> Event_log.Writer.append w (L2 u));
  Event_log.Writer.close w
;;

let date = Date.of_string "2026-01-01"

let%expect_test "rebuilt snapshot index matches the live writer byte for byte" =
  Sample.with_temp_dir (fun dir ->
    let%bind () = write_raw ~dir in
    let rebuilt = dir ^/ "rebuilt"
    and recorded = dir ^/ "recorded" in
    let%bind stats =
      Rebuild_norm.run
        ~normalizers:[ (module Sexp_l2) ]
        ~data_dir:dir
        ~out_dir:rebuilt
        date
    in
    print_s
      [%sexp
        (Or_error.map stats ~f:(fun s -> s.files, s.events, s.frame_errors)
         : (int * int * int) Or_error.t)];
    let%bind () = live ~dir:recorded in
    let index root = Snapshot_index.path ~dir:root Sample.btc date in
    print_endline (Sample.relative ~dir:rebuilt (index rebuilt));
    let%bind a = Reader.file_contents (index rebuilt)
    and b = Reader.file_contents (index recorded) in
    let%bind entries = Snapshot_index.load ~dir:rebuilt Sample.btc date in
    printf
      "entries %d, bytes %d, identical %b\n"
      (List.length entries)
      (String.length a)
      (String.equal a b);
    let%bind ev_a = Reader.file_contents (Event_log.path ~dir:rebuilt Sample.btc L2 date)
    and ev_b = Reader.file_contents (Event_log.path ~dir:recorded Sample.btc L2 date) in
    printf "event logs identical %b\n" (String.equal ev_a ev_b);
    [%expect
      {|
      (Ok (6 21 0))
      binance/BTCUSDT/norm/l2/_snapshots/2026-01-01.bin
      entries 5, bytes 765, identical true
      event logs identical true
      |}];
    return ())
;;

let%expect_test "a zero interval writes no index" =
  Sample.with_temp_dir (fun dir ->
    let%bind () = write_raw ~dir in
    let out_dir = dir ^/ "rebuilt" in
    let%bind (_ : Rebuild_norm.Stats.t) =
      Rebuild_norm.run
        ~snapshot_interval:Time_ns.Span.zero
        ~normalizers:[ (module Sexp_l2) ]
        ~data_dir:dir
        ~out_dir
        date
      >>| ok_exn
    in
    let%map exists =
      Sys.file_exists_exn (Snapshot_index.path ~dir:out_dir Sample.btc date)
    in
    print_s [%sexp (exists : bool)];
    [%expect {| false |}])
;;

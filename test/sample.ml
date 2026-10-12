open! Core
open Market_data

let btc = Instrument.create Binance "BTCUSDT"
let epoch = Time_ns.of_string_with_utc_offset "2026-01-01 00:00:00Z"
let ts ms = Time_ns.add epoch (Time_ns.Span.of_int_ms ms)

let trade ?(side = Side.Buy) ?id ~ms ~price ~size () : Trade.t =
  { instrument = btc
  ; exch_ts = ts ms
  ; recv_ts = ts (ms + 1)
  ; price = Price.of_string price
  ; size = Size.of_string size
  ; side
  ; trade_id = Option.value id ~default:(Int.to_string ms)
  }
;;

let bin_round_trip (type a) (module M : Binable.S with type t = a) ~equal (v : a) =
  let s = Binable.to_string (module M) v in
  let v' = Binable.of_string (module M) s in
  printf "bin_io: %d bytes, round trip %b\n" (String.length s) (equal v v')
;;

let with_temp_dir f =
  let open Async in
  let%bind dir = Unix.mkdtemp (Filename.temp_dir_name ^/ "market-data-test") in
  Monitor.protect
    (fun () -> f dir)
    ~finally:(fun () ->
      Process.run_expect_no_stdout_exn ~prog:"rm" ~args:[ "-rf"; dir ] ())
;;

let relative ~dir path =
  match String.chop_prefix path ~prefix:(dir ^ "/") with
  | Some p -> p
  | None -> path
;;

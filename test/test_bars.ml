open! Core
open Market_data

let ms t = Time_ns.Span.to_int_ms (Time_ns.diff t (Sample.ts 0))

let print_bar (b : Bars.Bar.t) =
  printf
    "%5d..%-5d n=%-3d o=%s h=%s l=%s c=%s v=%s buy=%s threshold=%g\n"
    (ms b.first_ts)
    (ms b.last_ts)
    b.trade_count
    (Price.to_string b.open_)
    (Price.to_string b.high)
    (Price.to_string b.low)
    (Price.to_string b.close)
    (Size.to_string b.volume)
    (Size.to_string b.buy_volume)
    b.threshold
;;

let run spec trades = List.iter (Bars.of_trades Sample.btc spec trades) ~f:print_bar

(* A deterministic tape: prices walk by one around 100, sizes cycle 1..4, the side of each
   trade (or [side]) follows the step from a linear congruential sequence. Built in order
   with a loop: [List.init] calls its function from the last index down. *)
let tape ?side ?(start = 0) n =
  let state = ref 12345 in
  let price = ref 100 in
  let acc = ref [] in
  for i = 0 to n - 1 do
    state := ((!state * 1103515245) + 12345) land 0x3fffffff;
    let up = !state land 0x10000 <> 0 in
    let delta = if up then 1 else -1 in
    price := !price + delta;
    let side = Option.value side ~default:(if up then Side.Buy else Sell) in
    acc
    := Sample.trade
         ~side
         ~ms:((start + i) * 100)
         ~price:(Int.to_string !price)
         ~size:(Int.to_string (1 + (i % 4)))
         ()
       :: !acc
  done;
  List.rev !acc
;;

let%expect_test "tick, volume and dollar bars" =
  let trades = tape 10 in
  run (Tick 4) trades;
  [%expect
    {|
      0..300   n=4   o=99 h=99 l=98 c=98 v=10 buy=3 threshold=4
    400..700   n=4   o=99 h=101 l=99 c=100 v=10 buy=6 threshold=4
    800..900   n=2   o=99 h=100 l=99 c=100 v=3 buy=2 threshold=4
    |}];
  (* The trade that crosses the threshold closes its bar whole. *)
  run (Volume (Size.of_string "6")) trades;
  [%expect
    {|
      0..200   n=3   o=99 h=99 l=98 c=99 v=6 buy=3 threshold=6
    300..500   n=3   o=98 h=100 l=98 c=100 v=7 buy=3 threshold=6
    600..700   n=2   o=101 h=101 l=100 c=100 v=7 buy=3 threshold=6
    800..900   n=2   o=99 h=100 l=99 c=100 v=3 buy=2 threshold=6
    |}];
  run (Dollar 700.) trades;
  [%expect
    {|
      0..300   n=4   o=99 h=99 l=98 c=98 v=10 buy=3 threshold=700
    400..700   n=4   o=99 h=101 l=99 c=100 v=10 buy=6 threshold=700
    800..900   n=2   o=99 h=100 l=99 c=100 v=3 buy=2 threshold=700
    |}]
;;

(* Trade counts of the bars; a [*] marks bars holding trades of the one-sided burst (trade
   times 30.0s to 35.9s). *)
let counts spec trades =
  Bars.of_trades Sample.btc spec trades
  |> List.map ~f:(fun (b : Bars.Bar.t) ->
    let burst = ms b.last_ts >= 30_000 && ms b.first_ts < 36_000 in
    sprintf "%d%s" b.trade_count (if burst then "*" else ""))
  |> String.concat ~sep:" "
  |> print_endline
;;

let%expect_test "imbalance and run bars close sooner on one-sided flow" =
  (* 300 trades of mixed flow, then 60 buys in a row, then mixed flow again. *)
  let trades = tape 300 @ tape ~side:Buy ~start:300 60 @ tape ~start:360 200 in
  let adaptive = { (Bars.Adaptive.default ~warmup_ticks:40) with min_ticks = 10 } in
  counts (Imbalance (Ticks, adaptive)) trades;
  [%expect
    {| 40 10 11 11 10 10 10 10 14 10 10 27 13 15 11 10 21 10 10 10 10 10 12* 10* 10* 10* 10* 10* 11* 49 20 29 23 14 10 18 10 10 10 1 |}];
  counts (Imbalance (Volume, adaptive)) trades;
  [%expect {| 40 52 18 24 11 46 10 71 36* 10* 10* 10* 10* 10* 97* 39 18 20 28 |}];
  counts (Run (Ticks, adaptive)) trades;
  [%expect {| 40 39 32 33 40 37 37 36 24* 19* 20* 40* 40 33 32 37 21 |}];
  counts (Run (Dollar, adaptive)) trades;
  [%expect {| 40 44 38 42 48 55 42* 22* 20* 32* 36 36 37 46 22 |}]
;;

let%expect_test "constant one-sided flow keeps imbalance bars at the warm-up length" =
  let adaptive = { (Bars.Adaptive.default ~warmup_ticks:20) with max_ticks = 30 } in
  let t = Bars.create Sample.btc (Imbalance (Ticks, adaptive)) in
  printf "warm-up threshold: %g\n" (Bars.threshold t);
  let bars = ref 0 in
  List.iter (tape ~side:Sell 400) ~f:(fun trade ->
    match Bars.add t trade with
    | This b ->
      incr bars;
      if !bars <= 4
      then printf "bar %d: %d trades, threshold %g\n" !bars b.trade_count b.threshold
    | Null -> ());
  printf "bars: %d, threshold now %g\n" !bars (Bars.threshold t);
  [%expect
    {|
    warm-up threshold: inf
    bar 1: 20 trades, threshold 20
    bar 2: 20 trades, threshold 20
    bar 3: 20 trades, threshold 20
    bar 4: 20 trades, threshold 20
    bars: 20, threshold now 20
    |}]
;;

let specs : Bars.Spec.t list =
  let a = Bars.Adaptive.default ~warmup_ticks:40 in
  [ Tick 5
  ; Volume (Size.of_string "3.5")
  ; Dollar 250.
  ; Imbalance (Ticks, a)
  ; Imbalance (Volume, a)
  ; Imbalance (Dollar, a)
  ; Run (Ticks, a)
  ; Run (Volume, a)
  ; Run (Dollar, a)
  ]
;;

let trade_gen =
  let open Quickcheck.Generator.Let_syntax in
  let%map price = Int.gen_incl 1 1_000_000
  and size = Int.gen_incl 1 1_000_000
  and side = Side.Stable.V1.quickcheck_generator in
  price, size, side
;;

let%test_unit "bars hold every trade once: counts, volumes and value add up" =
  Quickcheck.test
    ~trials:300
    (List.gen_with_length 200 trade_gen)
    ~sexp_of:[%sexp_of: (int * int * Side.t) list]
    ~f:(fun raw ->
      let trades =
        List.mapi raw ~f:(fun i (price, size, side) : Trade.t ->
          { (Sample.trade ~side ~ms:i ~price:"1" ~size:"1" ()) with
            price = Price.of_units (price * 1_000_000)
          ; size = Size.of_units size
          })
      in
      let total f = List.sum (module Int) trades ~f in
      List.iter specs ~f:(fun spec ->
        let bars = Bars.of_trades Sample.btc spec trades in
        let sum f = List.sum (module Int) bars ~f in
        [%test_result: int] (sum (fun b -> b.trade_count)) ~expect:(List.length trades);
        [%test_result: int]
          (sum (fun b -> Size.to_units b.volume))
          ~expect:(total (fun t -> Size.to_units t.size));
        [%test_result: int]
          (sum (fun b -> Size.to_units b.buy_volume))
          ~expect:
            (total (fun t ->
               match t.side with
               | Buy -> Size.to_units t.size
               | Sell -> 0));
        let value = List.sum (module Float) bars ~f:(fun b -> b.notional) in
        let expect =
          List.sum (module Float) trades ~f:(fun t ->
            Price.to_float t.price *. Size.to_float t.size)
        in
        if Float.(abs (value - expect) > 1e-9 *. expect)
        then raise_s [%message "notional" (value : float) (expect : float)];
        (* Bars tile the tape in order: each starts right after the previous one ends. *)
        ignore
          (List.fold bars ~init:0 ~f:(fun next (b : Bars.Bar.t) ->
             let first = (List.nth_exn trades next).exch_ts in
             [%test_result: Time_ns.t] b.first_ts ~expect:first;
             next + b.trade_count)
           : int)))
;;

(* Zero on arm64 and amd64: the state is a record with unboxed float fields written in
   place, and price and size are read as raw units. *)
let%expect_test "adding a trade that closes no bar allocates nothing" =
  List.iter specs ~f:(fun spec ->
    let t = Bars.create Sample.btc spec in
    let trades = Array.of_list (tape 2_000) in
    (* Warm up past the adaptive kinds' first bar. *)
    Array.iteri trades ~f:(fun i trade ->
      if i < 1_000 then ignore (Bars.add t trade : _ or_null));
    let words = ref 0 in
    let bars = ref 0 in
    for i = 1_000 to 1_999 do
      let before = Gc.minor_words () in
      match Bars.add t trades.(i) with
      | This _ -> incr bars
      | Null -> words := !words + (Gc.minor_words () - before)
    done;
    printf
      "%-22s %d words over %d trades closing no bar\n"
      (Bars.Spec.to_string spec)
      !words
      (1_000 - !bars));
  [%expect
    {|
    tick-5                 0 words over 800 trades closing no bar
    volume-3.5             0 words over 500 trades closing no bar
    dollar-250             0 words over 400 trades closing no bar
    tick-imbalance-40      0 words over 784 trades closing no bar
    volume-imbalance-40    0 words over 772 trades closing no bar
    dollar-imbalance-40    0 words over 769 trades closing no bar
    tick-run-40            0 words over 959 trades closing no bar
    volume-run-40          0 words over 961 trades closing no bar
    dollar-run-40          0 words over 976 trades closing no bar
    |}]
;;

let%expect_test "spec names" =
  List.iter specs ~f:(fun spec ->
    let name = Bars.Spec.to_string spec in
    printf "%s\n" name);
  List.iter
    [ "tick:500"
    ; "volume:2.5"
    ; "dollar:1e6"
    ; "volume-imbalance:100"
    ; "tick-run:50"
    ; "dollar:0"
    ; "range:1"
    ; "volume-imbalance:x"
    ]
    ~f:(fun s ->
      print_s [%sexp (s : string), (Bars.Spec.of_string s : Bars.Spec.t Or_error.t)]);
  [%expect
    {|
    tick-5
    volume-3.5
    dollar-250
    tick-imbalance-40
    volume-imbalance-40
    dollar-imbalance-40
    tick-run-40
    volume-run-40
    dollar-run-40
    (tick:500 (Ok (Tick 500)))
    (volume:2.5 (Ok (Volume 2.5)))
    (dollar:1e6 (Ok (Dollar 1000000)))
    (volume-imbalance:100
     (Ok
      (Imbalance Volume
       ((warmup_ticks 100) (span 20) (min_ticks 10) (max_ticks 1000)))))
    (tick-run:50
     (Ok (Run Ticks ((warmup_ticks 50) (span 20) (min_ticks 5) (max_ticks 500)))))
    (dollar:0 (Error ("Bars: threshold must be positive" (Dollar 0))))
    (range:1 (Error ("Bars: unknown bar spec" range:1)))
    (volume-imbalance:x (Error (Failure "Int.of_string: \"x\"")))
    |}]
;;

(* Pins the binary shape of a bar; a change needs a [Stable.V2]. *)
let%expect_test "bar shape" =
  print_endline [%bin_digest: Bars.Bar.Stable.V1.t];
  [%expect {| 351073e59d4be59ab0c3a0b3a51307fc |}]
;;

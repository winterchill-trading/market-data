open! Core
open Market_data

let config ?(classification = Toxicity.Classification.Aggressor) volume
  : Toxicity.Config.t
  =
  { bucket_volume = Size.of_string volume
  ; window = 5
  ; zscore_window = 20
  ; classification
  }
;;

let opt = Option.value_map ~default:"-" ~f:(sprintf "%+.2f")

let print (e : Toxicity.Event.t) =
  printf
    "bucket %2d  buy %5.2f sell %5.2f  imbalance %+.2f  vpin %.3f (%d)  z %s  cdf %s\n"
    e.bucket
    e.buy_volume
    e.sell_volume
    e.imbalance
    e.vpin
    e.buckets
    (opt e.zscore)
    (opt e.cdf)
;;

(* A balanced tape of one-unit trades alternating in pairs (buy, buy, sell, sell, ...),
   with [burst] consecutive buys from trade [at]. *)
let tape ?(at = 0) ?(burst = 0) n =
  List.init n ~f:(fun i ->
    let side =
      if i >= at && i < at + burst then Side.Buy else if i % 4 < 2 then Buy else Sell
    in
    Sample.trade ~side ~ms:(i * 100) ~price:"100" ~size:"1" ())
;;

let%expect_test "a one-sided burst moves VPIN and its z-score; balanced flow does not" =
  let events = Toxicity.of_trades Sample.btc (config "10") (tape ~at:300 ~burst:40 500) in
  List.iter events ~f:(fun e -> if e.bucket >= 24 && e.bucket <= 40 then print e);
  [%expect
    {|
    bucket 24  buy  6.00 sell  4.00  imbalance +0.20  vpin 0.200 (5)  z -  cdf +0.50
    bucket 25  buy  4.00 sell  6.00  imbalance -0.20  vpin 0.200 (5)  z -  cdf +0.50
    bucket 26  buy  6.00 sell  4.00  imbalance +0.20  vpin 0.200 (5)  z -  cdf +0.50
    bucket 27  buy  4.00 sell  6.00  imbalance -0.20  vpin 0.200 (5)  z -  cdf +0.50
    bucket 28  buy  6.00 sell  4.00  imbalance +0.20  vpin 0.200 (5)  z -  cdf +0.50
    bucket 29  buy  4.00 sell  6.00  imbalance -0.20  vpin 0.200 (5)  z -  cdf +0.50
    bucket 30  buy 10.00 sell  0.00  imbalance +1.00  vpin 0.360 (5)  z -  cdf +1.00
    bucket 31  buy 10.00 sell  0.00  imbalance +1.00  vpin 0.520 (5)  z +8.72  cdf +1.00
    bucket 32  buy 10.00 sell  0.00  imbalance +1.00  vpin 0.680 (5)  z +5.82  cdf +1.00
    bucket 33  buy 10.00 sell  0.00  imbalance +1.00  vpin 0.840 (5)  z +4.62  cdf +1.00
    bucket 34  buy  6.00 sell  4.00  imbalance +0.20  vpin 0.840 (5)  z +3.05  cdf +0.97
    bucket 35  buy  4.00 sell  6.00  imbalance -0.20  vpin 0.680 (5)  z +1.67  cdf +0.88
    bucket 36  buy  6.00 sell  4.00  imbalance +0.20  vpin 0.520 (5)  z +0.79  cdf +0.75
    bucket 37  buy  4.00 sell  6.00  imbalance -0.20  vpin 0.360 (5)  z +0.03  cdf +0.68
    bucket 38  buy  6.00 sell  4.00  imbalance +0.20  vpin 0.200 (5)  z -0.69  cdf +0.30
    bucket 39  buy  4.00 sell  6.00  imbalance -0.20  vpin 0.200 (5)  z -0.69  cdf +0.30
    bucket 40  buy  6.00 sell  4.00  imbalance +0.20  vpin 0.200 (5)  z -0.69  cdf +0.30
    |}];
  let spikes =
    List.filter_map events ~f:(fun e ->
      Option.bind e.zscore ~f:(fun z -> Option.some_if Float.(z > 3.) e.bucket))
  in
  print_s [%message (spikes : int list)];
  [%expect {| (spikes (31 32 33 34)) |}]
;;

let%expect_test "a large trade fills several buckets with its own split" =
  let t = Toxicity.create Sample.btc (config "4") in
  let add ?side ~ms size =
    List.iter (Toxicity.add t (Sample.trade ?side ~ms ~price:"100" ~size ())) ~f:print;
    printf "pending %.2f\n" (Toxicity.pending_volume t)
  in
  add ~ms:0 "3";
  add ~side:Sell ~ms:1 "10";
  [%expect
    {|
    pending 3.00
    bucket  0  buy  3.00 sell  1.00  imbalance +0.50  vpin 0.500 (1)  z -  cdf -
    bucket  1  buy  0.00 sell  4.00  imbalance -1.00  vpin 0.750 (2)  z -  cdf +1.00
    bucket  2  buy  0.00 sell  4.00  imbalance -1.00  vpin 0.833 (3)  z +1.18  cdf +1.00
    pending 1.00
    |}]
;;

let%expect_test "the tick rule recovers the aggressor side when sides follow ticks" =
  let prices = [ 100; 101; 101; 100; 99; 99; 100; 102; 101; 101; 100; 101 ] in
  (* Sides as the tick rule would infer them: up buys, down sells, a zero tick repeats. *)
  let sides =
    List.folding_mapi prices ~init:(100, Side.Buy) ~f:(fun i (prev, side) p ->
      let side =
        if i = 0 || p > prev then Side.Buy else if p < prev then Sell else side
      in
      (p, side), side)
  in
  let trades =
    List.mapi (List.zip_exn prices sides) ~f:(fun i (p, side) ->
      Sample.trade ~side ~ms:(i * 100) ~price:(Int.to_string p) ~size:"1.5" ())
  in
  let events c = Toxicity.of_trades Sample.btc (config ~classification:c "3") trades in
  let aggressor = events Aggressor in
  let tick_rule = events Tick_rule in
  List.iter aggressor ~f:print;
  (* The first trade has no previous price; the tick rule splits it evenly. *)
  print (List.hd_exn tick_rule);
  printf
    "same split from bucket 1 on: %b\n"
    ([%equal: (float * float) list]
       (List.tl_exn aggressor |> List.map ~f:(fun e -> e.buy_volume, e.sell_volume))
       (List.tl_exn tick_rule |> List.map ~f:(fun e -> e.buy_volume, e.sell_volume)));
  [%expect
    {|
    bucket  0  buy  3.00 sell  0.00  imbalance +1.00  vpin 1.000 (1)  z -  cdf -
    bucket  1  buy  1.50 sell  1.50  imbalance +0.00  vpin 0.500 (2)  z -  cdf +0.00
    bucket  2  buy  0.00 sell  3.00  imbalance -1.00  vpin 0.667 (3)  z -0.24  cdf +0.50
    bucket  3  buy  3.00 sell  0.00  imbalance +1.00  vpin 0.750 (4)  z +0.11  cdf +0.67
    bucket  4  buy  0.00 sell  3.00  imbalance -1.00  vpin 0.800 (5)  z +0.34  cdf +0.75
    bucket  5  buy  1.50 sell  1.50  imbalance +0.00  vpin 0.600 (5)  z -0.78  cdf +0.20
    bucket  0  buy  2.25 sell  0.75  imbalance +0.50  vpin 0.500 (1)  z -  cdf -
    same split from bucket 1 on: true
    |}]
;;

let%expect_test "bulk volume classification over one-second bars" =
  (* Ten trades a second; the price rises for 20 seconds, then falls. *)
  let trades =
    List.init 400 ~f:(fun i ->
      let s = i / 10 in
      let p = if s < 20 then 1000 + (s * 2) else 1040 - ((s - 20) * 2) in
      Sample.trade ~side:Sell ~ms:(i * 100) ~price:(Int.to_string p) ~size:"1" ())
  in
  let c = Toxicity.Classification.Bulk { interval = Time_ns.Span.second; span = 10 } in
  Toxicity.of_trades Sample.btc (config ~classification:c "20") trades
  |> List.iter ~f:(fun e -> if e.bucket % 3 = 0 then print e);
  [%expect
    {|
    bucket  0  buy 10.00 sell 10.00  imbalance +0.00  vpin 0.000 (1)  z -  cdf -
    bucket  3  buy 16.83 sell  3.17  imbalance +0.68  vpin 0.512 (4)  z +1.04  cdf +1.00
    bucket  6  buy 16.83 sell  3.17  imbalance +0.68  vpin 0.683 (5)  z +1.10  cdf +0.92
    bucket  9  buy 16.83 sell  3.17  imbalance +0.68  vpin 0.683 (5)  z +0.76  cdf +0.78
    bucket 12  buy  3.17 sell 16.83  imbalance -0.68  vpin 0.546 (5)  z +0.08  cdf +0.46
    bucket 15  buy  3.17 sell 16.83  imbalance -0.68  vpin 0.683 (5)  z +0.84  cdf +0.83
    bucket 18  buy  3.17 sell 16.83  imbalance -0.68  vpin 0.683 (5)  z +0.73  cdf +0.78
    |}]
;;

let%test_unit "buckets hold all the volume, each exactly the bucket size" =
  Quickcheck.test
    ~trials:200
    (List.gen_with_length
       100
       (Quickcheck.Generator.both
          (Int.gen_incl 1 500)
          Side.Stable.V1.quickcheck_generator))
    ~sexp_of:[%sexp_of: (int * Side.t) list]
    ~f:(fun raw ->
      List.iter
        [ Toxicity.Classification.Aggressor
        ; Tick_rule
        ; Bulk { interval = Time_ns.Span.of_int_ms 700; span = 5 }
        ]
        ~f:(fun classification ->
          let trades =
            List.mapi raw ~f:(fun i (size, side) ->
              Sample.trade
                ~side
                ~ms:(i * 100)
                ~price:(Int.to_string (100 + (i * 7 % 5)))
                ~size:(sprintf "%d.%02d" (size / 100) (size % 100))
                ())
          in
          let t = Toxicity.create Sample.btc (config ~classification "7.5") in
          let events = List.concat_map trades ~f:(Toxicity.add t) in
          (* Not [... @ Toxicity.flush t]: the right operand would run first. *)
          let events = events @ Toxicity.flush t in
          let total = List.sum (module Float) trades ~f:(fun t -> Size.to_float t.size) in
          let bucketed =
            List.sum (module Float) events ~f:(fun e -> e.buy_volume +. e.sell_volume)
          in
          List.iteri events ~f:(fun i e ->
            assert (e.bucket = i);
            assert (Float.(abs (e.buy_volume +. e.sell_volume - 7.5) < 1e-9));
            assert (Float.(e.vpin >= 0. && e.vpin <= 1.)));
          let missing = total -. bucketed -. Toxicity.pending_volume t in
          if Float.(abs missing > 1e-9)
          then raise_s [%message "volume lost" (missing : float)]))
;;

(* Zero on both platforms: the bucket accumulators are unboxed fields written in place and
   a trade that fills nothing returns the empty list. *)
let%expect_test "a trade that fills no bucket allocates nothing" =
  List.iter [ Toxicity.Classification.Aggressor; Tick_rule ] ~f:(fun classification ->
    let t = Toxicity.create Sample.btc (config ~classification "1000000") in
    let trades = Array.of_list (tape 1000) in
    let before = Gc.minor_words () in
    Array.iter trades ~f:(fun trade ->
      ignore (Toxicity.add t trade : Toxicity.Event.t list));
    printf
      "%s: %d words over 1000 trades\n"
      (Toxicity.Classification.to_string classification)
      (Gc.minor_words () - before));
  [%expect
    {|
    aggressor: 0 words over 1000 trades
    tick-rule: 0 words over 1000 trades
    |}]
;;

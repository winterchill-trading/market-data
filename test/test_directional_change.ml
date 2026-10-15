open! Core
open Market_data

let path prices = List.mapi prices ~f:(fun i p -> Sample.ts (i * 1000), Price.of_string p)
let s t = Time_ns.Span.to_int_sec (Time_ns.diff t (Sample.ts 0))

let print_dc (e : Directional_change.Event.t) =
  printf
    "%-4s turn at %ds %s, confirmed at %ds %s, overshoot %s\n"
    (Sexp.to_string [%sexp (e.direction : Directional_change.Direction.t)])
    (s e.extreme_ts)
    (Price.to_string e.extreme_price)
    (s e.confirm_ts)
    (Price.to_string e.confirm_price)
    (Option.value_map e.overshoot ~default:"-" ~f:(sprintf "%.4f"))
;;

let%expect_test "a hand-built path at theta = 5%" =
  let prices =
    path
      [ "100"
      ; "102"
      ; "98"
      ; "96"
      ; "101"
      ; "104"
      ; "110"
      ; "107"
      ; "104"
      ; "103"
      ; "100"
      ; "105"
      ; "108"
      ]
  in
  List.iter (Directional_change.of_prices ~theta:0.05 prices) ~f:print_dc;
  [%expect
    {|
    Down turn at 1s 102, confirmed at 3s 96, overshoot -
    Up   turn at 3s 96, confirmed at 4s 101, overshoot 0.0000
    Down turn at 6s 110, confirmed at 8s 104, overshoot 0.0891
    Up   turn at 10s 100, confirmed at 11s 105, overshoot 0.0385
    |}]
;;

let%expect_test "CUSUM on a drift and on an oscillation" =
  let drift = path (List.init 30 ~f:(fun i -> Int.to_string (100 + i))) in
  let oscillation =
    path (List.init 30 ~f:(fun i -> if i % 2 = 0 then "100" else "101"))
  in
  let print events =
    List.iter events ~f:(fun (e : Cusum_filter.Event.t) ->
      printf
        "%-4s at %ds %s (sum %.4f)\n"
        (Sexp.to_string [%sexp (e.direction : Directional_change.Direction.t)])
        (s e.time)
        (Price.to_string e.price)
        e.sum)
  in
  print (Cusum_filter.of_prices ~threshold:0.05 drift);
  [%expect
    {|
    Up   at 6s 106 (sum 0.0583)
    Up   at 12s 112 (sum 0.0551)
    Up   at 18s 118 (sum 0.0522)
    Up   at 25s 125 (sum 0.0576)
    |}];
  print (Cusum_filter.of_prices ~threshold:0.05 oscillation);
  [%expect {| |}]
;;

let walk_gen =
  let open Quickcheck.Generator.Let_syntax in
  List.gen_with_length 300 (Int.gen_incl (-300) 300)
  >>| fun steps ->
  List.folding_map steps ~init:1_000_000 ~f:(fun p step ->
    let p = Int.max 1_000 (p + step) in
    p, p)
;;

let%test_unit "directional changes alternate, overshoots are not negative, each reversal \
               is at least theta"
  =
  Quickcheck.test
    ~trials:300
    (Quickcheck.Generator.both walk_gen (Float.gen_incl 0.0005 0.02))
    ~sexp_of:[%sexp_of: int list * float]
    ~f:(fun (units, theta) ->
      let prices =
        List.mapi units ~f:(fun i u -> Sample.ts i, Price.of_units (u * 1_000))
      in
      let events = Directional_change.of_prices ~theta prices in
      List.iteri events ~f:(fun i (e : Directional_change.Event.t) ->
        assert (Time_ns.( <= ) e.extreme_ts e.confirm_ts);
        let x = Price.to_float e.extreme_price
        and c = Price.to_float e.confirm_price in
        (match e.direction with
         | Up ->
           assert (
             Float.( >= ) c (x *. (1. +. theta))
             || Float.( >= ) (c /. x) (1. +. theta -. 1e-12))
         | Down ->
           assert (
             Float.( <= ) c (x *. (1. -. theta))
             || Float.( <= ) (c /. x) (1. -. theta +. 1e-12)));
        match i, e.overshoot with
        | 0, None -> ()
        | 0, Some _ -> assert false
        | _, None -> assert false
        | _, Some o -> assert (Float.( >= ) o 0.));
      List.iter2_exn
        (List.drop_last events |> Option.value ~default:[])
        (List.tl events |> Option.value ~default:[])
        ~f:(fun (a : Directional_change.Event.t) b ->
          assert (not (Directional_change.Direction.equal a.direction b.direction))))
;;

(* Zero on both platforms: unboxed float state, written in place. *)
let%expect_test "prices that confirm nothing allocate nothing" =
  let dc = Directional_change.create ~theta:0.5 in
  let cusum = Cusum_filter.create ~threshold:0.5 in
  let time = Sample.ts 0 in
  let prices =
    Array.init 1000 ~f:(fun i -> Price.of_units ((100 + (i % 7)) * 100_000_000))
  in
  let before = Gc.minor_words () in
  Array.iter prices ~f:(fun p ->
    ignore (Directional_change.add dc ~time p : _ or_null);
    ignore (Cusum_filter.add cusum ~time p : _ or_null));
  printf "%d words\n" (Gc.minor_words () - before);
  [%expect {| 0 words |}]
;;

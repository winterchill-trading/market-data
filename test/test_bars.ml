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

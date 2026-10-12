open! Core
open Market_data

let level price size : L2_update.Level.t =
  { price = Price.of_string price; size = Size.of_string size }
;;

let update ~ms ~kind ~bids ~asks : L2_update.t =
  { instrument = Sample.btc
  ; exch_ts = Sample.ts ms
  ; recv_ts = Sample.ts ms
  ; kind
  ; bids
  ; asks
  }
;;

let%expect_test "snapshot, deltas and a new snapshot" =
  let show b =
    printf "snapshot %b\n%s---\n" (L2_book.has_snapshot b) (L2_book.to_string_hum b)
  in
  let b =
    L2_book.apply
      L2_book.empty
      (update ~ms:0 ~kind:Delta ~bids:[ level "99" "1" ] ~asks:[])
  in
  show b;
  let b =
    L2_book.apply
      b
      (update
         ~ms:1
         ~kind:Snapshot
         ~bids:[ level "99.9" "1"; level "99.8" "3" ]
         ~asks:[ level "100.1" "2"; level "100.25" "4" ])
  in
  show b;
  let b =
    L2_book.apply
      b
      (update
         ~ms:2
         ~kind:Delta
         ~bids:[ level "99.9" "0"; level "99.85" "7" ]
         ~asks:[ level "100.1" "1.5" ])
  in
  show b;
  print_s [%sexp (L2_book.bids ~depth:1 b : L2_update.Level.t list)];
  let b =
    L2_book.apply b (update ~ms:3 ~kind:Snapshot ~bids:[] ~asks:[ level "101" "1" ])
  in
  show b;
  [%expect
    {|
    snapshot false
    bid  99  1
    ---
    snapshot true
    ask  100.25  4
    ask   100.1  2
    bid    99.9  1
    bid    99.8  3
    ---
    snapshot true
    ask  100.25  4
    ask   100.1  1.5
    bid   99.85  7
    bid    99.8  3
    ---
    (((price 99.85) (size 7)))
    snapshot true
    ask  101  1
    ---
    |}]
;;

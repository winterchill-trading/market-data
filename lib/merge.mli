(** K-way merge of sorted pipes. *)

open! Core
open! Async

(** [sorted inputs ~compare] yields the values of every input in [compare] order, assuming
    each input is already sorted. Ties go to the input earlier in the list, so the merge
    is deterministic. The output closes once all inputs are exhausted; closing the output
    closes all inputs. Inputs are read in batches of up to 4096 values, merged without
    a Deferred bind per value, and written to the output one batch at a time. *)
val sorted : 'a Pipe.Reader.t list -> compare:('a -> 'a -> int) -> 'a Pipe.Reader.t

(** [sorted_by_key inputs ~key] is
    [sorted inputs ~compare:(fun a b -> Int.compare (key a) (key b))], with [key] called
    once per value and heap comparisons on the immediate keys. Use it when the order is an
    integer such as a timestamp in nanoseconds. *)
val sorted_by_key : 'a Pipe.Reader.t list -> key:('a -> int) -> 'a Pipe.Reader.t

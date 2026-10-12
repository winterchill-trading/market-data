(** K-way merge of sorted pipes. *)

open! Core
open! Async

(** [sorted inputs ~compare] yields the values of every input in [compare] order, assuming
    each input is already sorted. Ties go to the input earlier in the list, so the merge
    is deterministic. The output closes once all inputs are exhausted; closing the output
    closes all inputs. *)
val sorted : 'a Pipe.Reader.t list -> compare:('a -> 'a -> int) -> 'a Pipe.Reader.t

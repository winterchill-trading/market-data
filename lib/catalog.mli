(** What the [parquet/] tables under a root hold, from the file names alone. *)

open! Core
open! Async

module Entry : sig
  type t =
    { table : Parquet_kind.t
    ; venues : Venue.t list
    ; instruments : int (** venue and symbol pairs with at least one file *)
    ; first_date : Date.t
    ; last_date : Date.t
    ; files : int (** every [.parquet] file, parts included *)
    ; parts : string list
    (** numbered parts [<date>.<n>.parquet] a restarted sink left behind and no day close
        has merged yet, relative to the root *)
    }
  [@@deriving sexp_of, compare, equal]
end

(** One entry per table with files, in {!Parquet_kind.all} order. *)
val scan : dir:string -> Entry.t list Deferred.t

(** A fixed-width table, one line per entry, then the leftover parts. *)
val to_string_hum : Entry.t list -> string

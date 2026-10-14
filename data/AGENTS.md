# data: instrument catalogue

`instruments.sexp` lists each venue's instruments with kind (`Spot`, `Perp`, `Future`, `Option`),
base and quote, size unit (`Base`, `Quote` or contracts), funding interval, tick and lot.

Rules:

- Change this file when a venue lists or changes an instrument; the day-close instruments table
  reads it.
- Keep values as the venue documents them; cite the change in the commit message.
- It is data, not code: do not add comments that the parser must skip.

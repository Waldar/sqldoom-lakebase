# Roadmap

What is still open, and the ideas measured or weighed and dropped, so they are not tried again blindly. What shipped is in [CHANGELOG.md](CHANGELOG.md); the measurements are in [PERFORMANCE.md](PERFORMANCE.md) ("Tried and not kept").

## Open

* Delete `projects/sqldoom` (the old Postgres 17 project, kept as the rollback) once Postgres 19 has run for a few days.
* Input to picture with low detail on: the frame is about half of it, low detail should take 15-20 ms off (not measured yet).
* Cheats on Nightmare: Doom's `ST_Responder` turns them off on Nightmare (all but IDCLEV); this game keeps them on. Not decided.
* Cheat letters are read by key position (`ev.code`), so on an AZERTY keyboard the codes with A, Q, Z, W or M (IDDQD, IDKFA, IDFA, IDBEHOLDA, IDMYPOS) come out wrong; reading the typed letter (`ev.key`) would fix it. Not done.

## Considered and dropped

2026-11-24 to 11-26:

* DHTP high-resolution textures: they show only at 640x400 or more, an estimated 150-250 ms a frame (not built or measured).
* A no-shimmer frame view for frames without spectres: 3 ms slower once the choice is made inside the view.
* A CPU reserved for the tic, or the frames on read replicas: Postgres cannot reserve a CPU, and the replicas' lag made an older version unplayable.
* `REPACK (CONCURRENTLY)` instead of `VACUUM FULL`: little bloat in a game's branch, and slower than plain `REPACK`.

2026-11-20 (owner):

* Input on the frame socket (step 3 of the plan): the input's way in is about 14 ms of the 113 ms, the same network trip on either socket, and the database write stays; it would save about 1 ms.
* Doom's approximate sound distance (`P_AproxDistance`). (`D_INTER` came back with the intermission, 2026-11-21.)

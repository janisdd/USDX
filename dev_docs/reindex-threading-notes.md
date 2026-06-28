# Reindex threading notes

This note explains how companion-triggered reindexing works, why it is allowed to run in a background thread, why the macOS crash happened, and why reindexing still works after disabling the unsafe SDL/UI calls.

## High-level flow

The reindex routes do not directly modify the live song list from the HTTP handler.

Instead, the flow is:

1. HTTP route receives the reindex request.
2. The request is queued in `UCompanionServer`.
3. `TCompanionReindexQueueThread` picks up the queued request.
4. The worker thread parses song files into `Songs.SongListSafe`.
5. The worker thread posts a main-thread callback with `MainThreadExec(...)`.
6. The main thread merges the parsed songs into the live song list and refreshes UI-facing state.

So the system is intentionally split into:

- background-thread work: file scanning and song parsing
- main-thread work: merging into active data structures used by screens and UI

## Detailed flow

### 1. Routes enqueue work

The companion routes resolve the target path and enqueue a reindex request instead of executing it inline.

This keeps the HTTP request fast and avoids blocking the main thread.

### 2. Queue thread executes one reindex at a time

`TCompanionReindexQueueThread.Execute` pops one request from the queue and calls:

- `ExecuteReindexForPath(...)`

That method then calls:

- `Songs.BrowseTXTFilesSafe(SongPath)`

Important detail: this is not the UI thread. It is a dedicated worker thread.

### 3. Worker thread parses songs into a staging list

`TSongs.BrowseTXTFilesSafe(...)` does the expensive work:

- scans directories for `.txt` files
- creates temporary `TSong` objects
- calls `Song.Analyse`
- stores successful results in `SongListSafe`

This is safe to do on a worker thread because it is mostly:

- filesystem I/O
- string parsing
- object allocation
- building temporary in-memory song objects

It does **not** directly replace the active categorized song list while doing this.

It works against the staging list:

- `SongListSafe`

protected by:

- `BrowseTXTFilesSafeLock`

After parsing is done, it sets:

- `MergeSongListSafePending := true`

and then posts a main-thread callback:

- `MainThreadExec(@MergeSongListSafeInMainThread, Self)`

## Why main-thread handoff is needed

The live song state is not only a plain list of parsed songs. It is tied to UI-visible state:

- `SongList`
- `CatSongs`
- selection and visible indices
- playlist/category/filter restoration
- song screen refresh / thumbnails / covers

Those updates should happen on the main thread, because they affect state that screens may read immediately.

That is why `BrowseTXTFilesSafe(...)` only stages the parsed songs and then asks the main thread to finish the job.

## What `MainThreadExec(...)` actually does

`MainThreadExec(...)` does not call the function immediately from the worker thread.

Instead it pushes an SDL user event containing the callback pointer and data. The main SDL event loop later processes that event on the main thread and runs the callback there.

So this:

- `MainThreadExec(@MergeSongListSafeInMainThread, Self)`

means:

- "please run `MergeSongListSafeInMainThread` later on the main thread"

not:

- "run it now on this worker thread"

That callback then calls:

- `TSongs.MergeSongListSafeIfPending`

which finally performs the actual merge into the active song structures.

## Why reindexing still works on a background thread

Reindexing still works because the actual useful work was never the problem.

The useful work is:

- finding song files
- parsing them
- staging parsed results
- asking the main thread to merge them

All of that still happens.

What was unsafe on macOS was the worker thread trying to do **UI/event-loop work** while scanning files.

The broken calls were in `USongs`:

- `PumpSDLEvents()` -> calls `SDL_PollEvent`
- `SDL_SetWindowTitle(...)`

Those calls were added as progress/UI helpers during song discovery, but they are not required for reindex correctness.

So after guarding/disabling them for threaded discovery, reindexing still works because the core parse-and-merge pipeline was unchanged.

## Why macOS crashed

On macOS, SDL event polling ultimately goes through AppKit/Cocoa.

AppKit requires event retrieval to happen on the main thread.

The crash:

- `NSInternalInconsistencyException`
- `nextEventMatchingMask should only be called from the Main Thread!`

came from exactly that violation.

The stack trace showed:

- `USONGS_$$_PUMPSDLEVENTS`
- `SDL_PollEvent`
- Cocoa/AppKit event handling

while the code was running inside:

- `TCompanionReindexQueueThread.Execute`

That means the worker thread entered code that is only legal on the main thread.

## Why the fix is correct

The fix did **not** move reindexing to the main thread.

It only prevented the worker-thread discovery path from calling SDL/AppKit-facing helper code.

After the fix:

- initial startup discovery can still use the UI/progress helpers
- threaded reloads and companion reindexing do not call SDL event polling or window-title updates from the worker thread
- parsed songs are still staged in `SongListSafe`
- the merge still happens through `MainThreadExec(...)`

So the threading model remains:

- worker thread: parse
- main thread: merge / active UI state updates

which is the correct division of work.

## Relation to the lyrics bug

This is separate from the earlier lyrics bug.

The lyrics bug came from song parsing temporarily writing to the global `CurrentSong` while another song was already being sung.

That issue was fixed by making `TSong.Analyse()` parse into `Self` without changing the global `CurrentSong`.

The crash issue was different:

- it came from SDL/AppKit event polling on a worker thread

So there were two separate bugs:

1. parser touched global active song state
2. worker thread touched SDL/AppKit event-loop APIs

Both were triggered by background reindexing, but they had different root causes.

## Short version

Background reindexing still works because:

- parsing songs in the background is safe
- merging results into active UI state is deferred to the main thread

The macOS crash happened because:

- the background thread also tried to pump SDL/AppKit events

The fix works because:

- it removed only the unsafe worker-thread UI/event calls
- it kept the background parse + main-thread merge design intact

# Reindex queue notes

This note explains how the companion reindex queue works in `UCompanionServer.pas`.

It focuses on:

- what is stored in the queue
- how requests are added
- how duplicate requests are avoided
- how only one reindex runs at a time
- what `queueLength` means in API responses
- how queue state is initialized and cleaned up

## Main queue data structures

The queue is implemented with a few globals:

- `ReindexQueueThread: TCompanionReindexQueueThread`
- `ReindexQueueLock: TRTLCriticalSection`
- `ReindexQueue: TList`
- `ActiveReindexSongPath: IPath`

The queued item type is:

- `TCompanionQueuedReindex`

which contains:

- `SongPath: IPath`
- `LogLabel: UTF8String`

So each queued request is basically:

- "please reindex this normalized path"
- "use this label for logging"

## What gets queued

The queue stores reindex requests after the route layer has already resolved the incoming request to a real song/root path.

That means the queue is not storing raw JSON or route-specific parameters. It stores a normalized internal request:

- target path
- log label

This keeps the worker thread simple because it only has to process paths.

## Path normalization

Before a request is queued, the path is normalized by:

- converting it to an absolute path
- removing the trailing path delimiter

That is done by:

- `NormalizeReindexPath(...)`

This matters because different path spellings should still count as the same queued work item.

Examples:

- `/songs/foo/`
- `/songs/foo`

should represent the same reindex target.

## Duplicate suppression

The queue intentionally allows at most one pending request per path.

This is implemented in:

- `IsReindexPathQueuedUnsafe(...)`
- `EnqueueReindexRequest(...)`

`EnqueueReindexRequest(...)` first normalizes the path, then enters `ReindexQueueLock`, then checks whether an equivalent path is already in `ReindexQueue`.

If the path is already pending:

- it does **not** add another queued item
- it returns `AlreadyQueued := true`

If the path is not pending:

- it creates a new `TCompanionQueuedReindex`
- appends it to `ReindexQueue`

Important detail: duplicate suppression only checks the **pending queue list**.

It does not compare against `ActiveReindexSongPath` when deciding whether to append.

That means:

- if a path is already waiting in the queue, a new request for the same path is ignored
- if a path is currently being processed, another request for that path may still be queued for a later pass

That behavior is intentional and useful:

- a request arriving while a path is already running can schedule one more pass afterward
- many repeated requests while one extra pass is already pending still collapse down to just one future run

So the queue behaves like:

- one active request
- at most one pending request per path

not:

- unlimited duplicates

## Single-flight execution

`TCompanionReindexQueueThread.Execute` ensures only one reindex runs at a time.

The logic is:

1. loop until terminated
2. enter `ReindexQueueLock`
3. if no reindex is active and the queue has items:
   - take the first item from `ReindexQueue`
   - remove it from the list
   - set `ActiveReindexSongPath`
4. release the lock
5. if a request was taken:
   - call `ExecuteReindexForPath(...)`
   - when finished, clear `ActiveReindexSongPath` under lock
   - free the request object
6. if no request was available:
   - sleep for 250 ms

Two things are important here:

- the actual reindex work is done **outside** the critical section
- `ActiveReindexSongPath` is used as the "single-flight" marker

This means:

- queue operations stay fast
- the lock is not held during file scanning / parsing
- only one worker pass is active even if many requests arrive

## FIFO behavior

The queue uses a `TList`, and the worker always takes:

- `ReindexQueue[0]`

then deletes index `0`.

So pending requests are processed in FIFO order:

- first queued
- first executed

subject to duplicate suppression.

## Meaning of `ActiveReindexSongPath`

`ActiveReindexSongPath` is not the queue itself.

It represents:

- the request currently being executed by the worker thread

Its main purposes are:

- preventing the worker from starting a second request at the same time
- letting API responses report queue length more accurately
- making current activity visible in logs / state

While a reindex is running:

- `ActiveReindexSongPath <> nil`

When idle:

- `ActiveReindexSongPath = nil`

## Meaning of `queueLength`

`EnqueueReindexRequest(...)` returns `QueueLength` to the route handler.

This value is computed as:

- `ReindexQueue.Count`
- plus `1` if `ActiveReindexSongPath <> nil`

So `queueLength` means:

- total outstanding work

not:

- only pending items sitting in the list

Example:

- 1 active run, 2 waiting in `ReindexQueue`
- reported `queueLength = 3`

This is a better user-facing number because it describes how much work remains overall.

## Why some helpers are called `Unsafe`

Helpers like:

- `IsReindexPathQueuedUnsafe(...)`
- `ClearReindexQueueUnsafe`

are marked "unsafe" because they assume the caller already holds `ReindexQueueLock`.

That is a naming convention to prevent accidental unlocked access.

So:

- `Unsafe` does not mean "buggy"
- it means "must be called while the queue lock is already held"

## Startup behavior

When `StartCompanionServer(...)` runs, it initializes queue state under the lock:

- creates `ReindexQueue` if needed
- otherwise clears any old queued entries
- resets `ActiveReindexSongPath := nil`

Then it starts:

- `ReindexQueueThread`

This ensures the queue starts from a clean state each time the companion server starts.

## Shutdown behavior

When `StopCompanionServer` runs:

1. the HTTP server is stopped
2. the queue thread is terminated and waited for
3. under `ReindexQueueLock`, remaining queued requests are freed
4. `ReindexQueue` is freed
5. `ActiveReindexSongPath` is reset to `nil`

This prevents:

- leaked queued request objects
- stale queue state surviving across shutdown/startup

## Why the queue is needed at all

The queue solves several problems:

- avoids doing expensive file parsing inside the HTTP request handler
- serializes reindex operations so multiple requests do not run in parallel
- collapses repeated requests for the same path
- allows later requests to be remembered while one request is already running

Without the queue, repeated companion calls could:

- block request handling
- race with each other
- duplicate work unnecessarily
- make song list updates much harder to reason about

## Short version

The queue behaves like this:

- routes enqueue normalized path-based reindex requests
- only one request runs at a time
- duplicate pending requests for the same path are collapsed
- one currently running request is tracked separately with `ActiveReindexSongPath`
- worker-thread parsing happens first
- live-state merge happens later on the main thread

That makes the reindex system predictable, serialized, and reasonably efficient under repeated companion requests.

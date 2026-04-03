{* UltraStar Deluxe - Companion HTTP Server
 *
 * This unit starts a lightweight HTTP server that can receive JSON requests.
 * The server runs asynchronously and must not block the main thread.
 *}
unit UCompanionServer;

interface

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

{$I switches.inc}

procedure StartCompanionServer(Port: integer; const PlaylistName: UTF8String);
procedure StopCompanionServer;

implementation

uses
  Classes,
  SysUtils,
  UCompanionHelpers,
  UIni,
  ULog,
  UPath,
  UPathUtils,
  UPlaylist,
  USongs,
  UDisplay,
  UGraphic,
  sdl2
  {$IFDEF FPC}
  , fphttpserver
  , httpdefs
  , httproute
  , fpjson
  , jsonparser
  {$ENDIF}
  ;

{$IFDEF FPC}
type
  TCompanionReindexThrottleThread = class(TThread)
  protected
    procedure Execute; override;
  end;

  TCompanionServerThread = class(TThread)
  private
    FHttpServer: TFPHTTPServer;
    FRouter: THTTPRouter;
    FPort: integer;
    procedure HandleRequest(Sender: TObject; var ARequest: TFPHTTPConnectionRequest;
      var AResponse: TFPHTTPConnectionResponse);
  public
    constructor Create(APort: integer);
    procedure StopServer;
  protected
    procedure Execute; override;
  end;

var
  CompanionServerThread: TCompanionServerThread = nil;
  ReindexThrottleThread: TCompanionReindexThrottleThread = nil;
  ReindexThrottleLock: TRTLCriticalSection;
  LastReindexRunAtMs: QWord = 0;
  PendingReindex: Boolean = false;
  PendingReindexSongPath: IPath = nil;
  PendingReindexSongsDirName: UTF8String = '';

function FindPlaylistIndexByName(const PlaylistName: UTF8String): Integer; forward;
procedure EnsureCompanionPlaylist(const PlaylistName: UTF8String); forward;
function TryParseSongRequest(const Body: string; out Title, Artist: UTF8String): boolean; forward;
procedure HandleAddSongsRequest(const Songs: TCompanionSongArray; out ResponseJson: UTF8String;
  out ResponseCode: Integer); forward;
procedure HandleSelectSongRequest(const Title, Artist: UTF8String; out ResponseJson: UTF8String;
  out ResponseCode: Integer); forward;
procedure HandleStartSelectedSongRequest(out ResponseJson: UTF8String; out ResponseCode: Integer); forward;
procedure HandleSetCompanionPlaylistRequest(const Songs: TCompanionSongArray; out ResponseJson: UTF8String;
  out ResponseCode: Integer); forward;
procedure HandleReindexDirRequest(const Request: TCompanionReindexDirRequest; out ResponseJson: UTF8String;
  out ResponseCode: Integer); forward;
procedure HandleReindexSingleSongDirRequest(const Request: TCompanionReindexSingleSongDirRequest;
  out ResponseJson: UTF8String; out ResponseCode: Integer); forward;
procedure SetErrorResponse(out ResponseJson: UTF8String; out ResponseCode: Integer;
  const Message: UTF8String; Code: Integer); forward;
function GetReindexThrottleWindowMs: QWord; forward;
procedure ExecuteReindexForPath(const SongPath: IPath); forward;
function TryScheduleReindex(const SongPath: IPath; const SongsDirName: UTF8String;
  out RetryAfterMs: QWord): Boolean; forward;
procedure CompanionRouteSetCompanionPlaylist(ARequest: TRequest; AResponse: TResponse); forward;
procedure CompanionRouteAddToCompanionPlaylist(ARequest: TRequest; AResponse: TResponse); forward;
procedure CompanionRouteReindexDir(ARequest: TRequest; AResponse: TResponse); forward;
procedure CompanionRouteReindexSingleSongDir(ARequest: TRequest; AResponse: TResponse); forward;
procedure CompanionRouteCurrentSong(ARequest: TRequest; AResponse: TResponse); forward;
procedure CompanionRouteSelectSong(ARequest: TRequest; AResponse: TResponse); forward;
procedure CompanionRouteStartSelectedSong(ARequest: TRequest; AResponse: TResponse); forward;
procedure CompanionRouteNotFound(ARequest: TRequest; AResponse: TResponse); forward;
procedure RegisterCompanionRoutes(ARouter: THTTPRouter); forward;

type
  TMainThreadExecProc = procedure(Data: Pointer);
  PSelectSongData = ^TSelectSongData;
  TSelectSongData = record
    SongIndex: Integer;
  end;

const
  MAINTHREAD_EXEC_EVENT = SDL_USEREVENT + 2;

procedure ExecInMainThread(Proc: TMainThreadExecProc; Data: Pointer);
var
  Event: TSDL_Event;
begin
  with Event.user do
  begin
    type_ := MAINTHREAD_EXEC_EVENT;
    code  := 0;
    data1 := @Proc;
    data2 := Data;
  end;
  SDL_PushEvent(@Event);
end;

procedure SelectSongInUi(Data: Pointer);
var
  SelectData: PSelectSongData;
  Target: Integer;
  VisibleIndex: Integer;
begin
  SelectData := PSelectSongData(Data);
  try
    if (SelectData = nil) then
      Exit;

    Target := SelectData^.SongIndex;
    if (Target < Low(CatSongs.Song)) or (Target > High(CatSongs.Song)) then
      Exit;
    if (not Assigned(ScreenSong)) then
      Exit;
    if (not CatSongs.Song[Target].Visible) then
      Exit;

    VisibleIndex := CatSongs.VisibleIndex(Target);
    ScreenSong.SkipTo(VisibleIndex, Target, CatSongs.VisibleSongs);
    ScreenSong.FixSelected;
    ScreenSong.FixSelected2;
    ScreenSong.ChangeMusic;
  finally
    Dispose(SelectData);
  end;
end;

procedure StartSelectedSongInUi(Data: Pointer);
begin
  if (ScreenSong = nil) then
    Exit;
  ScreenSong.ParseInput(SDLK_RETURN, 0, true);
end;

procedure TCompanionReindexThrottleThread.Execute;
var
  SongPath: IPath;
  SongsDirName: UTF8String;
  NowMs: QWord;
  WindowMs: QWord;
begin
  while not Terminated do
  begin
    SongPath := nil;
    SongsDirName := '';
    WindowMs := GetReindexThrottleWindowMs();

    System.EnterCriticalSection(ReindexThrottleLock);
    try
      if PendingReindex and (LastReindexRunAtMs <> 0) then
      begin
        NowMs := GetTickCount64();
        if (NowMs - LastReindexRunAtMs >= WindowMs) then
        begin
          SongPath := PendingReindexSongPath;
          SongsDirName := PendingReindexSongsDirName;
          PendingReindex := false;
          PendingReindexSongPath := nil;
          PendingReindexSongsDirName := '';
          LastReindexRunAtMs := NowMs;
        end;
      end;
    finally
      System.LeaveCriticalSection(ReindexThrottleLock);
    end;

    if (SongPath <> nil) then
    begin
      Log.LogStatus('Companion', 'Executing trailing reindex for songsDirName: ' + SongsDirName);
      ExecuteReindexForPath(SongPath);
    end
    else
      Sleep(50);
  end;
end;

procedure TCompanionServerThread.HandleRequest(Sender: TObject; var ARequest: TFPHTTPConnectionRequest;
  var AResponse: TFPHTTPConnectionResponse);
var
  Body: string;
begin
  Body := ARequest.Content;
  if (Body <> '') then
    Log.LogStatus('Companion', 'JSON request: ' + Body)
  else
    Log.LogStatus('Companion', 'Request: ' + ARequest.Method + ' ' + ARequest.URI);

  AResponse.ContentType := 'application/json';
  FRouter.RouteRequest(ARequest, AResponse);
end;

constructor TCompanionServerThread.Create(APort: integer);
begin
  inherited Create(false);
  FreeOnTerminate := true;
  FPort := APort;
end;

procedure TCompanionServerThread.Execute;
begin
  FRouter := THTTPRouter.Create(nil);
  try
    RegisterCompanionRoutes(FRouter);
    FHttpServer := TFPHTTPServer.Create(nil);
    try
      FHttpServer.Port := Word(FPort);
      FHttpServer.Threaded := true;
      FHttpServer.OnRequest := HandleRequest;
      FHttpServer.Active := true;

      Log.LogStatus('Companion', 'HTTP server listening on port ' + IntToStr(FPort));

      while not Terminated do
        Sleep(50);
    finally
      if (FHttpServer <> nil) then
      begin
        FHttpServer.Active := false;
        FreeAndNil(FHttpServer);
      end;
    end;
  finally
    FreeAndNil(FRouter);
  end;
end;

procedure TCompanionServerThread.StopServer;
begin
  Terminate;
  if (FHttpServer <> nil) then
    FHttpServer.Active := false;
end;
{$ENDIF}

function FindPlaylistIndexByName(const PlaylistName: UTF8String): Integer;
var
  I: Integer;
begin
  Result := -1;
  if (PlayListMan = nil) then
    Exit;

  for I := 0 to High(PlayListMan.Playlists) do
  begin
    if (CompareText(PlayListMan.Playlists[I].Name, PlaylistName) = 0) then
    begin
      Result := I;
      Exit;
    end;
  end;
end;

procedure EnsureCompanionPlaylist(const PlaylistName: UTF8String);
var
  Index: Integer;
begin
  if (Trim(PlaylistName) = '') then
    Exit;

  if (PlayListMan = nil) then
  begin
    Log.LogStatus('Companion', 'Playlist manager not ready');
    Exit;
  end;

  Index := FindPlaylistIndexByName(PlaylistName);
  if (Index = -1) then
  begin
    PlayListMan.AddPlaylist(PlaylistName);
    Log.LogStatus('Companion', 'Created playlist: ' + PlaylistName);
  end;
end;

function TryParseSongRequest(const Body: string; out Title, Artist: UTF8String): boolean;
var
  Data: TJSONData;
  Obj: TJSONObject;
begin
  Result := false;
  Title := '';
  Artist := '';

  if (Trim(Body) = '') then
    Exit;

  Data := GetJSON(Body);
  try
    if (Data.JSONType <> jtObject) then
      Exit;
    Obj := TJSONObject(Data);

    Title := Obj.Get('title', '');
    Artist := Obj.Get('artist', '');

    Result := (Trim(Title) <> '') and (Trim(Artist) <> '');
  finally
    Data.Free;
  end;
end;

function FindSongByArtistTitle(const Artist, Title: UTF8String): Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := Low(CatSongs.Song) to High(CatSongs.Song) do
  begin
    if (CatSongs.Song[I].Title = Title) and (CatSongs.Song[I].Artist = Artist) then
    begin
      Result := I;
      Exit;
    end;
  end;
end;

procedure SetErrorResponse(out ResponseJson: UTF8String; out ResponseCode: Integer;
  const Message: UTF8String; Code: Integer);
begin
  ResponseJson := '{"ok":false,"error":"' + Message + '"}';
  ResponseCode := Code;
end;

function GetReindexThrottleWindowMs: QWord;
var
  WindowSec: Integer;
begin
  WindowSec := Ini.CompanionReindexThrottleWindowSec;
  if (WindowSec <= 0) then
    WindowSec := 5;
  Result := QWord(WindowSec) * 1000;
end;

procedure ExecuteReindexForPath(const SongPath: IPath);
var
  NormalizedSongPath: IPath;
begin
  if (SongPath = nil) then
    Exit;
  if (Songs = nil) then
  begin
    Log.LogStatus('Companion', 'Skipping reindex because Songs subsystem is not ready');
    Exit;
  end;

  NormalizedSongPath := SongPath.RemovePathDelim();
  Log.LogStatus('Companion', 'Reindex requested for song path: ' + UTF8String(NormalizedSongPath.ToNative()));
  Songs.BrowseTXTFilesSafe(SongPath);
  Log.LogStatus('Companion', 'Reindex completed for song path: ' + UTF8String(NormalizedSongPath.ToNative()));
end;

function TryScheduleReindex(const SongPath: IPath; const SongsDirName: UTF8String;
  out RetryAfterMs: QWord): Boolean;
var
  NowMs: QWord;
  ElapsedMs: QWord;
  WindowMs: QWord;
begin
  Result := true;
  RetryAfterMs := 0;
  NowMs := GetTickCount64();
  WindowMs := GetReindexThrottleWindowMs();

  System.EnterCriticalSection(ReindexThrottleLock);
  try
    if (LastReindexRunAtMs <> 0) then
    begin
      ElapsedMs := NowMs - LastReindexRunAtMs;
      if (ElapsedMs < WindowMs) then
      begin
        RetryAfterMs := WindowMs - ElapsedMs;
        PendingReindex := true;
        PendingReindexSongPath := SongPath;
        PendingReindexSongsDirName := SongsDirName;
        Result := false;
        Exit;
      end;
    end;

    LastReindexRunAtMs := NowMs;
    PendingReindex := false;
    PendingReindexSongPath := nil;
    PendingReindexSongsDirName := '';
  finally
    System.LeaveCriticalSection(ReindexThrottleLock);
  end;
end;

procedure HandleAddSongsRequest(const Songs: TCompanionSongArray; out ResponseJson: UTF8String;
  out ResponseCode: Integer);
var
  PlaylistName: UTF8String;
  Index: Integer;
  SongId: Integer;
  I: Integer;
  SongIds: array of Integer;
  FoundCount: Integer;
begin
  PlaylistName := UTF8String(Ini.CompanionPlaylistName);
  if (Trim(PlaylistName) = '') then
  begin
    SetErrorResponse(ResponseJson, ResponseCode, 'CompanionPlaylistName not set', 500);
    Exit;
  end;

  EnsureCompanionPlaylist(PlaylistName);
  Index := FindPlaylistIndexByName(PlaylistName);
  if (Index = -1) then
  begin
    SetErrorResponse(ResponseJson, ResponseCode, 'Playlist unavailable', 500);
    Exit;
  end;

  FoundCount := 0;
  if (Length(Songs) > 0) then
    SetLength(SongIds, Length(Songs));
  for I := 0 to High(Songs) do
  begin
    SongId := FindSongByArtistTitle(Songs[I].Artist, Songs[I].Title);
    if (SongId = -1) then
    begin
      Log.LogWarn('Song not found: ' + Songs[I].Artist + ' - ' + Songs[I].Title, 'Companion');
      Continue;
    end;
    SongIds[FoundCount] := SongId;
    Inc(FoundCount);
  end;
  if (Length(SongIds) <> FoundCount) then
    SetLength(SongIds, FoundCount);

  for I := 0 to High(SongIds) do
    PlayListMan.AddItem(SongIds[I], Index);
  Log.LogStatus('Companion', 'Added ' + IntToStr(Length(SongIds)) + ' songs to ' + PlaylistName);
  ResponseJson := '{"ok":true}';
  ResponseCode := 200;
end;

procedure HandleSelectSongRequest(const Title, Artist: UTF8String; out ResponseJson: UTF8String;
  out ResponseCode: Integer);
var
  SongId: Integer;
  Data: PSelectSongData;
begin
  if (Display = nil) or (Display.CurrentScreen <> @ScreenSong) then
  begin
    SetErrorResponse(ResponseJson, ResponseCode, 'Not on song select screen', 409);
    Exit;
  end;

  SongId := FindSongByArtistTitle(Artist, Title);
  if (SongId = -1) then
  begin
    SetErrorResponse(ResponseJson, ResponseCode, 'Song not found', 404);
    Exit;
  end;

  New(Data);
  Data^.SongIndex := SongId;
  ExecInMainThread(@SelectSongInUi, Data);

  Log.LogStatus('Companion', 'Selected song ' + IntToStr(SongId) + ': ' + Artist + ' - ' + Title);
  ResponseJson := '{"ok":true}';
  ResponseCode := 200;
end;

procedure HandleStartSelectedSongRequest(out ResponseJson: UTF8String; out ResponseCode: Integer);
begin
  if (Display = nil) or (Display.CurrentScreen <> @ScreenSong) then
  begin
    SetErrorResponse(ResponseJson, ResponseCode, 'Not on song select screen', 409);
    Exit;
  end;

  if (not Assigned(ScreenSong)) or (not Assigned(CatSongs)) then
  begin
    SetErrorResponse(ResponseJson, ResponseCode, 'Song screen not ready', 503);
    Exit;
  end;

  if (Songs.SongList.Count = 0) or (Length(CatSongs.Song) = 0) then
  begin
    SetErrorResponse(ResponseJson, ResponseCode, 'No songs loaded', 409);
    Exit;
  end;

  if (ScreenSong.Interaction < Low(CatSongs.Song)) or
     (ScreenSong.Interaction > High(CatSongs.Song)) then
  begin
    SetErrorResponse(ResponseJson, ResponseCode, 'No song selected', 409);
    Exit;
  end;

  ExecInMainThread(@StartSelectedSongInUi, nil);
  Log.LogStatus('Companion', 'Start selected song (simulated Enter)');
  ResponseJson := '{"ok":true}';
  ResponseCode := 200;
end;

procedure HandleSetCompanionPlaylistRequest(const Songs: TCompanionSongArray; out ResponseJson: UTF8String;
  out ResponseCode: Integer);
var
  PlaylistName: UTF8String;
  Index: Integer;
  SongId: Integer;
  I: Integer;
  WasExisting: Boolean;
  SongIds: array of Integer;
  FoundCount: Integer;
begin
  PlaylistName := UTF8String(Ini.CompanionPlaylistName);
  if (Trim(PlaylistName) = '') then
  begin
    SetErrorResponse(ResponseJson, ResponseCode, 'CompanionPlaylistName not set', 500);
    Exit;
  end;

  WasExisting := FindPlaylistIndexByName(PlaylistName) <> -1;
  EnsureCompanionPlaylist(PlaylistName);
  Index := FindPlaylistIndexByName(PlaylistName);
  if (Index = -1) then
  begin
    SetErrorResponse(ResponseJson, ResponseCode, 'Playlist unavailable', 500);
    Exit;
  end;

  FoundCount := 0;
  if (Length(Songs) > 0) then
    SetLength(SongIds, Length(Songs));
  for I := 0 to High(Songs) do
  begin
    SongId := FindSongByArtistTitle(Songs[I].Artist, Songs[I].Title);
    if (SongId = -1) then
    begin
      Log.LogWarn('Song not found: ' + Songs[I].Artist + ' - ' + Songs[I].Title, 'Companion');
      Continue;
    end;
    SongIds[FoundCount] := SongId;
    Inc(FoundCount);
  end;
  if (Length(SongIds) <> FoundCount) then
    SetLength(SongIds, FoundCount);

  if WasExisting then
  begin
    SetLength(PlayListMan.Playlists[Index].Items, 0);
    PlayListMan.SavePlayList(Index);
    if (CatSongs.CatNumShow = -3) and (Index = PlayListMan.CurPlaylist) then
      PlayListMan.SetPlaylist(Index);
  end;

  for I := 0 to High(SongIds) do
    PlayListMan.AddItem(SongIds[I], Index);

  Log.LogStatus('Companion', 'Set playlist ' + PlaylistName + ' with ' + IntToStr(Length(SongIds)) + ' songs');
  ResponseJson := '{"ok":true}';
  ResponseCode := 200;
end;

procedure HandleReindexDirRequest(const Request: TCompanionReindexDirRequest; out ResponseJson: UTF8String;
  out ResponseCode: Integer);
var
  I: Integer;
  SongsDirName: UTF8String;
  SongPath: IPath;
  SongPathText: UTF8String;
  RetryAfterMs: QWord;
begin
  SongsDirName := Trim(Request.SongsDirName);
  if (SongsDirName = '') then
  begin
    SetErrorResponse(ResponseJson, ResponseCode, 'songsDirName must not be empty', 400);
    Exit;
  end;

  if (Songs = nil) then
  begin
    SetErrorResponse(ResponseJson, ResponseCode, 'Songs subsystem not ready', 503);
    Exit;
  end;

  if (SongPaths <> nil) then
  begin
    for I := 0 to SongPaths.Count - 1 do
    begin
      SongPath := SongPaths[I] as IPath;
      SongPathText := UTF8String(SongPath.RemovePathDelim().ToUTF8(false));

      if (Length(SongPathText) >= Length(SongsDirName)) and
         (CompareText(Copy(SongPathText, Length(SongPathText) - Length(SongsDirName) + 1, Length(SongsDirName)), SongsDirName) = 0) then
      begin
        if not TryScheduleReindex(SongPath, SongsDirName, RetryAfterMs) then
        begin
          Log.LogStatus('Companion', 'Queued trailing reindex for songsDirName: ' + SongsDirName);
          ResponseJson := '{"ok":true,"queued":true,"retryAfterMs":' + IntToStr(RetryAfterMs) + '}';
          ResponseCode := 202;
          Exit;
        end;

        ExecuteReindexForPath(SongPath);
        ResponseJson := '{"ok":true}';
        ResponseCode := 200;
        Exit;
      end;
    end;
  end;

  SetErrorResponse(ResponseJson, ResponseCode, 'Songs directory not found: ' + SongsDirName, 404);
end;

procedure HandleReindexSingleSongDirRequest(const Request: TCompanionReindexSingleSongDirRequest;
  out ResponseJson: UTF8String; out ResponseCode: Integer);
var
  I: Integer;
  SingleName: UTF8String;
  SinglePath: IPath;
  RootPath: IPath;
  RetryAfterMs: QWord;
  LogLabel: UTF8String;
begin
  SingleName := Trim(Request.SingleSongDirName);
  if (SingleName = '') then
  begin
    SetErrorResponse(ResponseJson, ResponseCode, 'singleSongDirName must not be empty', 400);
    Exit;
  end;

  if (Songs = nil) then
  begin
    SetErrorResponse(ResponseJson, ResponseCode, 'Songs subsystem not ready', 503);
    Exit;
  end;

  SinglePath := Path(SingleName).GetAbsolutePath().RemovePathDelim();
  if (not SinglePath.Exists()) then
  begin
    SetErrorResponse(ResponseJson, ResponseCode, 'Song directory not found: ' + SingleName, 404);
    Exit;
  end;
  if (not SinglePath.IsDirectory()) then
  begin
    SetErrorResponse(ResponseJson, ResponseCode, 'singleSongDirName must be a directory', 400);
    Exit;
  end;

  if (SongPaths <> nil) then
  begin
    for I := 0 to SongPaths.Count - 1 do
    begin
      RootPath := (SongPaths[I] as IPath).GetAbsolutePath().RemovePathDelim();
      if SinglePath.IsChildOf(RootPath, false) then
      begin
        LogLabel := UTF8String(SinglePath.ToUTF8(false));
        if not TryScheduleReindex(SinglePath, LogLabel, RetryAfterMs) then
        begin
          Log.LogStatus('Companion', 'Queued trailing reindex for singleSongDir: ' + LogLabel);
          ResponseJson := '{"ok":true,"queued":true,"retryAfterMs":' + IntToStr(RetryAfterMs) + '}';
          ResponseCode := 202;
          Exit;
        end;

        ExecuteReindexForPath(SinglePath);
        ResponseJson := '{"ok":true}';
        ResponseCode := 200;
        Exit;
      end;
    end;
  end;

  SetErrorResponse(ResponseJson, ResponseCode,
    'Song directory is not under a configured songs root: ' + SingleName, 404);
end;

{$IFDEF FPC}

procedure CompanionRouteSetCompanionPlaylist(ARequest: TRequest; AResponse: TResponse);
var
  Body: string;
  Songs: TCompanionSongArray;
  ResponseJson: UTF8String;
  ResponseCode: Integer;
begin
  Body := ARequest.Content;
  if not TryParseSongsRequest(Body, Songs) then
    SetErrorResponse(ResponseJson, ResponseCode, 'Invalid JSON', 400)
  else
    HandleSetCompanionPlaylistRequest(Songs, ResponseJson, ResponseCode);
  AResponse.Code := ResponseCode;
  AResponse.Content := ResponseJson;
end;

procedure CompanionRouteAddToCompanionPlaylist(ARequest: TRequest; AResponse: TResponse);
var
  Body: string;
  Songs: TCompanionSongArray;
  ResponseJson: UTF8String;
  ResponseCode: Integer;
begin
  Body := ARequest.Content;
  if not TryParseSongsRequest(Body, Songs) then
    SetErrorResponse(ResponseJson, ResponseCode, 'Invalid JSON', 400)
  else
    HandleAddSongsRequest(Songs, ResponseJson, ResponseCode);
  AResponse.Code := ResponseCode;
  AResponse.Content := ResponseJson;
end;

procedure CompanionRouteReindexDir(ARequest: TRequest; AResponse: TResponse);
var
  Body: string;
  ReindexDirRequest: TCompanionReindexDirRequest;
  ResponseJson: UTF8String;
  ResponseCode: Integer;
begin
  Body := ARequest.Content;
  if not TryParseReindexDirRequest(Body, ReindexDirRequest) then
    SetErrorResponse(ResponseJson, ResponseCode, 'Invalid JSON', 400)
  else
    HandleReindexDirRequest(ReindexDirRequest, ResponseJson, ResponseCode);
  AResponse.Code := ResponseCode;
  AResponse.Content := ResponseJson;
end;

procedure CompanionRouteReindexSingleSongDir(ARequest: TRequest; AResponse: TResponse);
var
  Body: string;
  Req: TCompanionReindexSingleSongDirRequest;
  ResponseJson: UTF8String;
  ResponseCode: Integer;
begin
  Body := ARequest.Content;
  if not TryParseReindexSingleSongDirRequest(Body, Req) then
    SetErrorResponse(ResponseJson, ResponseCode, 'Invalid JSON', 400)
  else
    HandleReindexSingleSongDirRequest(Req, ResponseJson, ResponseCode);
  AResponse.Code := ResponseCode;
  AResponse.Content := ResponseJson;
end;

procedure CompanionRouteCurrentSong(ARequest: TRequest; AResponse: TResponse);
var
  ResponseJson: UTF8String;
begin
  ResponseJson := GenerateCurrentSongJson;
  AResponse.Code := 200;
  AResponse.Content := ResponseJson;
end;

procedure CompanionRouteSelectSong(ARequest: TRequest; AResponse: TResponse);
var
  Body: string;
  Title: UTF8String;
  Artist: UTF8String;
  ResponseJson: UTF8String;
  ResponseCode: Integer;
begin
  Body := ARequest.Content;
  if not TryParseSongRequest(Body, Title, Artist) then
    SetErrorResponse(ResponseJson, ResponseCode, 'Invalid JSON', 400)
  else
    HandleSelectSongRequest(Title, Artist, ResponseJson, ResponseCode);
  AResponse.Code := ResponseCode;
  AResponse.Content := ResponseJson;
end;

procedure CompanionRouteStartSelectedSong(ARequest: TRequest; AResponse: TResponse);
var
  ResponseJson: UTF8String;
  ResponseCode: Integer;
begin
  if CompareText(ARequest.Method, 'POST') <> 0 then
  begin
    SetErrorResponse(ResponseJson, ResponseCode, 'Method not allowed', 405);
    AResponse.Code := ResponseCode;
    AResponse.Content := ResponseJson;
    Exit;
  end;
  HandleStartSelectedSongRequest(ResponseJson, ResponseCode);
  AResponse.Code := ResponseCode;
  AResponse.Content := ResponseJson;
end;

procedure CompanionRouteNotFound(ARequest: TRequest; AResponse: TResponse);
var
  ResponseJson: UTF8String;
  ResponseCode: Integer;
begin
  Log.LogStatus('Companion', 'Unknown route: ' + ARequest.Method + ' ' + ARequest.URI);
  SetErrorResponse(ResponseJson, ResponseCode, 'Unknown route', 404);
  AResponse.Code := ResponseCode;
  AResponse.Content := ResponseJson;
end;

procedure RegisterCompanionRoutes(ARouter: THTTPRouter);
begin
  ARouter.RegisterRoute('/setCompanionPlaylist', @CompanionRouteSetCompanionPlaylist);
  ARouter.RegisterRoute('/addToCompanionPlaylist', @CompanionRouteAddToCompanionPlaylist);
  ARouter.RegisterRoute('/reindexRootDir', @CompanionRouteReindexDir);
  ARouter.RegisterRoute('/reindexSingleSongDir', @CompanionRouteReindexSingleSongDir);
  ARouter.RegisterRoute('/currentSong', @CompanionRouteCurrentSong);
  ARouter.RegisterRoute('/selectSong', @CompanionRouteSelectSong);
  ARouter.RegisterRoute('/startSelectedSong', @CompanionRouteStartSelectedSong);
  ARouter.RegisterRoute('*', @CompanionRouteNotFound, True);
end;

{$ENDIF}

procedure StartCompanionServer(Port: integer; const PlaylistName: UTF8String);
begin
  EnsureCompanionPlaylist(PlaylistName);

  if (Port <= 0) then
    Exit;

  {$IFDEF FPC}
  if (CompanionServerThread <> nil) then
    Exit;

  System.EnterCriticalSection(ReindexThrottleLock);
  try
    LastReindexRunAtMs := 0;
    PendingReindex := false;
    PendingReindexSongPath := nil;
    PendingReindexSongsDirName := '';
  finally
    System.LeaveCriticalSection(ReindexThrottleLock);
  end;

  if (ReindexThrottleThread = nil) then
    ReindexThrottleThread := TCompanionReindexThrottleThread.Create(false);

  CompanionServerThread := TCompanionServerThread.Create(Port);
  {$ELSE}
  Log.LogStatus('Companion', 'HTTP server not available in Delphi build');
  {$ENDIF}
end;

procedure StopCompanionServer;
begin
  {$IFDEF FPC}
  if (CompanionServerThread <> nil) then
  begin
    CompanionServerThread.StopServer;
    CompanionServerThread := nil;
  end;
  if (ReindexThrottleThread <> nil) then
  begin
    ReindexThrottleThread.Terminate;
    ReindexThrottleThread.WaitFor;
    FreeAndNil(ReindexThrottleThread);
  end;

  System.EnterCriticalSection(ReindexThrottleLock);
  try
    LastReindexRunAtMs := 0;
    PendingReindex := false;
    PendingReindexSongPath := nil;
    PendingReindexSongsDirName := '';
  finally
    System.LeaveCriticalSection(ReindexThrottleLock);
  end;
  {$ENDIF}
end;

initialization
  System.InitCriticalSection(ReindexThrottleLock);

finalization
  {$IFDEF FPC}
  if (ReindexThrottleThread <> nil) then
  begin
    ReindexThrottleThread.Terminate;
    ReindexThrottleThread.WaitFor;
    FreeAndNil(ReindexThrottleThread);
  end;
  {$ENDIF}
  System.DoneCriticalSection(ReindexThrottleLock);

end.

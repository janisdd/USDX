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
  UIni,
  ULog,
  UPlaylist,
  USongs,
  UDisplay,
  UGraphic,
  sdl2
  {$IFDEF FPC}
  , fphttpserver
  , fpjson
  , jsonparser
  {$ENDIF}
  ;

{$IFDEF FPC}
type
  TCompanionServerThread = class(TThread)
  private
    FHttpServer: TFPHTTPServer;
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

function FindPlaylistIndexByName(const PlaylistName: UTF8String): Integer; forward;
procedure EnsureCompanionPlaylist(const PlaylistName: UTF8String); forward;
function TryParseSongRequest(const Body: string; out Title, Artist: UTF8String): boolean; forward;
type
  TCompanionSong = record
    Title: UTF8String;
    Artist: UTF8String;
  end;
  TCompanionSongArray = array of TCompanionSong;

function TryParseSongsRequest(const Body: string; out Songs: TCompanionSongArray): boolean; forward;
procedure HandleAddSongsRequest(const Songs: TCompanionSongArray; out ResponseJson: UTF8String;
  out ResponseCode: Integer); forward;
procedure HandleSelectSongRequest(const Title, Artist: UTF8String; out ResponseJson: UTF8String;
  out ResponseCode: Integer); forward;
procedure HandleSetCompanionPlaylistRequest(const Songs: TCompanionSongArray; out ResponseJson: UTF8String;
  out ResponseCode: Integer); forward;
procedure SetErrorResponse(out ResponseJson: UTF8String; out ResponseCode: Integer;
  const Message: UTF8String; Code: Integer); forward;

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

procedure TCompanionServerThread.HandleRequest(Sender: TObject; var ARequest: TFPHTTPConnectionRequest;
  var AResponse: TFPHTTPConnectionResponse);
var
  Body: string;
  Songs: TCompanionSongArray;
  ResponseJson: UTF8String;
  ResponseCode: Integer;
  Path: string;
begin
  Body := ARequest.Content;
  if (Body <> '') then
    Log.LogStatus('Companion', 'JSON request: ' + Body)
  else
    Log.LogStatus('Companion', 'Request: ' + ARequest.Method + ' ' + ARequest.URI);

  AResponse.ContentType := 'application/json';
  Path := ARequest.PathInfo;
  if (Path = '') then
    Path := ARequest.URI;

  ResponseCode := 200;
  if (Path = '/setCompanionPlaylist') then
  begin
    if not TryParseSongsRequest(Body, Songs) then
      SetErrorResponse(ResponseJson, ResponseCode, 'Invalid JSON', 400)
    else
      HandleSetCompanionPlaylistRequest(Songs, ResponseJson, ResponseCode);
  end
  else if (Path = '/addToCompanionPlaylist') then
  begin
    if not TryParseSongsRequest(Body, Songs) then
      SetErrorResponse(ResponseJson, ResponseCode, 'Invalid JSON', 400)
    else
      HandleAddSongsRequest(Songs, ResponseJson, ResponseCode);
  end
  else
  begin
    if not TryParseSongRequest(Body, Title, Artist) then
      SetErrorResponse(ResponseJson, ResponseCode, 'Invalid JSON', 400)
    else if (Path = '/selectSong') then
      HandleSelectSongRequest(Title, Artist, ResponseJson, ResponseCode)
    else
      SetErrorResponse(ResponseJson, ResponseCode, 'Unknown route', 404);
  end;

  AResponse.Code := ResponseCode;
  AResponse.Content := ResponseJson;
end;

constructor TCompanionServerThread.Create(APort: integer);
begin
  inherited Create(false);
  FreeOnTerminate := true;
  FPort := APort;
end;

procedure TCompanionServerThread.Execute;
begin
  try
    FHttpServer := TFPHTTPServer.Create(nil);
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

function TryParseSongsRequest(const Body: string; out Songs: TCompanionSongArray): boolean;
var
  Data: TJSONData;
  Obj: TJSONObject;
  SongsData: TJSONData;
  SongsArray: TJSONArray;
  ItemObj: TJSONObject;
  I: Integer;
  Title: UTF8String;
  Artist: UTF8String;
begin
  Result := false;
  SetLength(Songs, 0);

  if (Trim(Body) = '') then
    Exit;

  Data := GetJSON(Body);
  try
    if (Data.JSONType <> jtObject) then
      Exit;
    Obj := TJSONObject(Data);

    SongsData := Obj.Find('songs');
    if (SongsData = nil) or (SongsData.JSONType <> jtArray) then
      Exit;

    SongsArray := TJSONArray(SongsData);
    if (SongsArray.Count > 0) then
      SetLength(Songs, SongsArray.Count);
    for I := 0 to SongsArray.Count - 1 do
    begin
      if (SongsArray.Items[I].JSONType <> jtObject) then
        Exit;
      ItemObj := TJSONObject(SongsArray.Items[I]);
      Title := ItemObj.Get('title', '');
      Artist := ItemObj.Get('artist', '');
      if (Trim(Title) = '') or (Trim(Artist) = '') then
        Exit;
      Songs[I].Title := Title;
      Songs[I].Artist := Artist;
    end;

    Result := true;
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

procedure StartCompanionServer(Port: integer; const PlaylistName: UTF8String);
begin
  EnsureCompanionPlaylist(PlaylistName);

  if (Port <= 0) then
    Exit;

  {$IFDEF FPC}
  if (CompanionServerThread <> nil) then
    Exit;

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
  {$ENDIF}
end;

end.

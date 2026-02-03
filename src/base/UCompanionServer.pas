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
  USongs
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
procedure HandleAddSongRequest(const Title, Artist: UTF8String; out ResponseJson: UTF8String); forward;

procedure TCompanionServerThread.HandleRequest(Sender: TObject; var ARequest: TFPHTTPConnectionRequest;
  var AResponse: TFPHTTPConnectionResponse);
var
  Body: string;
  Title: UTF8String;
  Artist: UTF8String;
  ResponseJson: UTF8String;
begin
  Body := ARequest.Content;
  if (Body <> '') then
    Log.LogStatus('Companion', 'JSON request: ' + Body)
  else
    Log.LogStatus('Companion', 'Request: ' + ARequest.Method + ' ' + ARequest.URI);

  AResponse.ContentType := 'application/json';
  if TryParseSongRequest(Body, Title, Artist) then
    HandleAddSongRequest(Title, Artist, ResponseJson)
  else
    ResponseJson := '{"ok":false,"error":"Invalid JSON"}';

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

procedure HandleAddSongRequest(const Title, Artist: UTF8String;
  out ResponseJson: UTF8String);
var
  PlaylistName: UTF8String;
  Index: Integer;
  SongId: Integer;
begin
  PlaylistName := UTF8String(Ini.CompanionPlaylistName);
  if (Trim(PlaylistName) = '') then
  begin
    ResponseJson := '{"ok":false,"error":"CompanionPlaylistName not set"}';
    Exit;
  end;

  EnsureCompanionPlaylist(PlaylistName);
  Index := FindPlaylistIndexByName(PlaylistName);
  if (Index = -1) then
  begin
    ResponseJson := '{"ok":false,"error":"Playlist unavailable"}';
    Exit;
  end;

  SongId := FindSongByArtistTitle(Artist, Title);
  if (SongId = -1) then
  begin
    ResponseJson := '{"ok":false,"error":"Song not found"}';
    Exit;
  end;

  PlayListMan.AddItem(SongId, Index);
  Log.LogStatus('Companion', 'Added song ' + IntToStr(SongId) + ' to ' + PlaylistName);
  ResponseJson := '{"ok":true}';
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

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

procedure StartCompanionServer(Port: integer);
procedure StopCompanionServer;

implementation

uses
  SysUtils,
  ULog
  {$IFDEF FPC}
  , fphttpserver
  {$ENDIF}
  ;

{$IFDEF FPC}
type
  TCompanionServer = class
  private
    FHttpServer: TFPHTTPServer;
    procedure HandleRequest(Sender: TObject; var ARequest: TFPHTTPConnectionRequest;
      var AResponse: TFPHTTPConnectionResponse);
  public
    constructor Create(APort: integer);
    destructor Destroy; override;
  end;

var
  CompanionServer: TCompanionServer = nil;

procedure TCompanionServer.HandleRequest(Sender: TObject; var ARequest: TFPHTTPConnectionRequest;
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
  AResponse.Content := '{"ok":true}';
end;

constructor TCompanionServer.Create(APort: integer);
begin
  inherited Create;
  FHttpServer := TFPHTTPServer.Create(nil);
  FHttpServer.Port := Word(APort);
  FHttpServer.Threaded := true;
  FHttpServer.OnRequest := HandleRequest;
  FHttpServer.Active := true;

  Log.LogStatus('Companion', 'HTTP server listening on port ' + IntToStr(APort));
end;

destructor TCompanionServer.Destroy;
begin
  if (FHttpServer <> nil) then
  begin
    FHttpServer.Active := false;
    FreeAndNil(FHttpServer);
  end;
  inherited Destroy;
end;
{$ENDIF}

procedure StartCompanionServer(Port: integer);
begin
  if (Port <= 0) then
    Exit;

  {$IFDEF FPC}
  if (CompanionServer <> nil) then
    Exit;

  CompanionServer := TCompanionServer.Create(Port);
  {$ELSE}
  Log.LogStatus('Companion', 'HTTP server not available in Delphi build');
  {$ENDIF}
end;

procedure StopCompanionServer;
begin
  {$IFDEF FPC}
  if (CompanionServer <> nil) then
  begin
    FreeAndNil(CompanionServer);
  end;
  {$ENDIF}
end;

end.

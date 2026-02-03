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
  Classes,
  SysUtils,
  ULog
  {$IFDEF FPC}
  , fphttpserver
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
  AResponse.Content := '{"ok":true}';
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

procedure StartCompanionServer(Port: integer);
begin
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

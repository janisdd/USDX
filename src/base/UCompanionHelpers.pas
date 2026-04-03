{* UltraStar Deluxe - Companion HTTP helpers (JSON parsing and payloads) *}
unit UCompanionHelpers;

interface

{$IFDEF FPC}
  {$MODE Delphi}
{$ENDIF}

{$I switches.inc}

uses
  SysUtils;

type
  TCompanionSong = record
    Title: UTF8String;
    Artist: UTF8String;
  end;
  TCompanionReindexDirRequest = record
    SongsDirName: UTF8String;
  end;
  TCompanionReindexSingleSongDirRequest = record
    SingleSongDirName: UTF8String;
  end;
  TCompanionSongArray = array of TCompanionSong;

{$IFDEF FPC}
function TryParseSongsRequest(const Body: string; out Songs: TCompanionSongArray): boolean;
function TryParseReindexDirRequest(const Body: string; out Request: TCompanionReindexDirRequest): boolean;
function TryParseReindexSingleSongDirRequest(const Body: string; out Request: TCompanionReindexSingleSongDirRequest): boolean;
function GenerateCurrentSongJson: UTF8String;
{$ENDIF}

implementation

{$IFDEF FPC}

uses
  fpjson,
  jsonparser,
  UDisplay,
  UGraphic,
  UNote;

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

function TryParseReindexDirRequest(const Body: string; out Request: TCompanionReindexDirRequest): boolean;
var
  Data: TJSONData;
  Obj: TJSONObject;
begin
  Result := false;
  Request.SongsDirName := '';

  if (Trim(Body) = '') then
    Exit;

  Data := GetJSON(Body);
  try
    if (Data.JSONType <> jtObject) then
      Exit;
    Obj := TJSONObject(Data);

    Request.SongsDirName := Obj.Get('songsDirName', '');
    Result := Trim(Request.SongsDirName) <> '';
  finally
    Data.Free;
  end;
end;

function TryParseReindexSingleSongDirRequest(const Body: string; out Request: TCompanionReindexSingleSongDirRequest): boolean;
var
  Data: TJSONData;
  Obj: TJSONObject;
begin
  Result := false;
  Request.SingleSongDirName := '';

  if (Trim(Body) = '') then
    Exit;

  Data := GetJSON(Body);
  try
    if (Data.JSONType <> jtObject) then
      Exit;
    Obj := TJSONObject(Data);

    Request.SingleSongDirName := Obj.Get('singleSongDirName', '');
    Result := Trim(Request.SingleSongDirName) <> '';
  finally
    Data.Free;
  end;
end;

function GenerateCurrentSongJson: UTF8String;
var
  SongDetails: TJSONObject;
  JSONRoot: TJSONObject;
begin
  JSONRoot := TJSONObject.Create;
  try
    if Assigned(CurrentSong) and (Display <> nil) and (Display.CurrentScreen = @ScreenSing) then
    begin
      JSONRoot.Add('playing', true);
      SongDetails := TJSONObject.Create;
      SongDetails.Add('artist', UTF8Encode(CurrentSong.Artist));
      SongDetails.Add('title', UTF8Encode(CurrentSong.Title));
      SongDetails.Add('genre', UTF8Encode(CurrentSong.Genre));
      SongDetails.Add('year', CurrentSong.Year);
      SongDetails.Add('language', UTF8Encode(CurrentSong.Language));
      SongDetails.Add('edition', UTF8Encode(CurrentSong.Edition));
      SongDetails.Add('lang', UTF8Encode(CurrentSong.Language));

      // not important for us
      // if CurrentSong.Creator <> '' then
      //   SongDetails.Add('creator', UTF8Encode(CurrentSong.Creator))
      // else
      //   SongDetails.Add('creator', TJSONNull.Create);

      // SongDetails.Add('duet', CurrentSong.isDuet);
      // SongDetails.Add('hasRap', CurrentSong.hasRap);

      JSONRoot.Add('song', SongDetails);
    end
    else
    begin
      JSONRoot.Add('playing', false);
      JSONRoot.Add('song', TJSONNull.Create);
    end;
    Result := UTF8String(JSONRoot.AsJSON);
  finally
    JSONRoot.Free;
  end;
end;

{$ENDIF}

end.

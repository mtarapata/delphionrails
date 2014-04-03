unit dorUIB;
{$I uib.inc}

interface
uses
{$IFDEF MSWINDOWS}
  windows,
{$ENDIF}
  dorDB, uibase, uiblib, supertypes, superobject, superdate, syncobjs, dorUtils,
  Generics.Collections;

type
  TDBUIBConnectionPool = class(TInterfacedObject, IDBConnectionPool)
  private
    FCriticalSection: TCriticalSection;
    FMax: Integer;
    FDatabase: string;
    FUserName: string;
    FPassword: string;
    FCharacterset: string;
    FLib: string;
    FPool: TList<IDBConnection>;
  protected
    function Connection: IDBConnection;
    function Size: Integer;
    procedure ClearPool;
    procedure Lock;
    procedure Unlock;
  public
    constructor Create(Max: Integer; const Database, Username, Password: string;
      const Characterset: string = 'UTF8'; const Lib: string = ''); reintroduce;
    destructor Destroy; override;
  end;

  TDBUIBConnection = class(TDBConnection)
  private
    FLibrary: TUIBLibrary;
    FDbHandle: IscDbHandle;
    FCharacterSet: TCharacterSet;
  protected
    function Transaction(const OtherConnections: array of IDBConnection; const Options: ISuperObject = nil): IDBTransaction; overload; override;
    function Transaction(const Options: ISuperObject = nil): IDBTransaction; overload; override;
  public
    constructor Create(const Database, Username, Password: string;
      const Characterset: string = 'UTF8'; const Lib: string = ''); virtual;
    destructor Destroy; override;
  end;

  TDBUIBTransaction = class(TDBTransaction)
  private
    FRollback: Boolean;
    FTrHandle: IscTrHandle;
    FConnection: IDBConnection;
  protected
    procedure ExecuteImmediate(const Options: SOString); override;
    function Query(const Sql: string; const Connection: IDBConnection = nil): IDBQuery; override;
  public
    constructor Create(const Connections: array of TDBUIBConnection; const Options: ISuperObject); reintroduce;
    destructor Destroy; override;
  end;

  TDBUIBQuery = class(TDBQuery)
  private
    FStHandle: IscStmtHandle;
    FConnection: IDBConnection;
    FSQLResult: TSQLResult;
    FSQLParams: TSQLParams;
    FStatementType: TUIBStatementType;
  protected
    function Execute(const Params: ISuperObject; Options: TQueryOptions; const Transaction: IDBTransaction): ISuperObject; override;
    function GetInputMeta: ISuperObject; override;
    function GetOutputMeta(byindex: Boolean): ISuperObject; override;
  public
    constructor Create(const Connection: IDBConnection; const Trans: TDBUIBTransaction; const Sql: string); reintroduce;
    destructor Destroy; override;
  end;

  function GetUIBConnections: Integer;

implementation
uses sysutils;

var
  UIBConnections: Integer = 0;

function GetUIBConnections: Integer;
begin
  Result := UIBConnections;
end;

{ TDBUIBConnection }

constructor TDBUIBConnection.Create(const Database, Username, Password,
  Characterset, Lib: string);
var
  option: string;
begin
  inherited Create;
  InterlockedIncrement(UIBConnections);
  FDbHandle := nil;
  FLibrary := TUIBLibrary.Create;

  if lib <> '' then
    FLibrary.Load(lib) else
    FLibrary.Load(GetClientLibrary);

  option := 'sql_dialect=3';

  if username <> '' then
    option := option + ';user_name=' + username;

  if password <> '' then
    option := option + ';password=' + password;

  if characterset <> '' then
    FCharacterSet := StrToCharacterSet(AnsiString(characterset)) else
    FCharacterSet := GetSystemCharacterset;
  option := option + ';lc_ctype=' + string(CharacterSetStr[FCharacterSet]);

  if database <> '' then
    FLibrary.AttachDatabase(AnsiString(database), FDbHandle, AnsiString(option)) else
    FDbHandle := nil;
end;

destructor TDBUIBConnection.Destroy;
begin
  if FDbHandle <> nil then
    FLibrary.DetachDatabase(FDbHandle);
  FLibrary.Free;
  InterlockedDecrement(UIBConnections);
  inherited;
end;

function TDBUIBConnection.Transaction(
  const OtherConnections: array of IDBConnection;
  const Options: ISuperObject): IDBTransaction;
var
  Cnx: IDBConnection;
  Arr: array of TDBUIBConnection;
  I: Integer;
begin
  SetLength(Arr, 1 + Length(OtherConnections));
  Arr[0] := Self;
  I := 1;
  for Cnx in OtherConnections do
    if (Cnx <> nil) and (Cnx is TDBUIBConnection) then
    begin
      Arr[I] := TDBUIBConnection(Cnx);
      Inc(I);
    end;
  SetLength(Arr, I);
  Result := TDBUIBTransaction.Create(Arr, Options);
end;

function TDBUIBConnection.Transaction(const Options: ISuperObject): IDBTransaction;
begin
  Result := TDBUIBTransaction.Create([Self], Options);
end;

{ TDBUIBContext }

constructor TDBUIBTransaction.Create(const Connections: array of TDBUIBConnection; const Options: ISuperObject);
var
  params: RawByteString;
  lockread, lockwrite: string;
  opt: TTransParams;
  prm: TTransParam;
  obj, arr: ISuperObject;
  dic: TDictionary<string, TTransParam>;
{$IFDEF FB20_UP}
  locktimeout: Integer;
{$ENDIF}
  buffer: PISCTEB;
  i: Integer;
begin
  Assert(Length(Connections) > 0);
  inherited Create;
//  Merge(Options, true);
  FConnection := Connections[0];
  //AsObject['connection'] := Connections[0];
  FTrHandle := nil;
  if ObjectIsType(Options, stObject) then
  begin
    lockread := '';
    lockwrite := '';
    for obj in Options.N['lockread'] do
      if lockread <> '' then
        lockread := lockread + ',' + obj.AsString else
        lockread := obj.AsString;

    for obj in Options.N['lockwrite'] do
      if lockwrite <> '' then
        lockwrite := lockwrite + ',' + obj.AsString else
        lockwrite := obj.AsString;

    opt := [];
{$IFDEF FB20_UP}
    locktimeout := 0;
{$ENDIF}
    arr := Options.AsObject['options'];
    if ObjectIsType(arr, stArray) and (arr.AsArray.Length > 0) then
    begin
      dic := TDictionary<string, TTransParam>.Create(Ord(High(TTransParam)) + 1);
      try
        dic.Add('consistency', tpConsistency);
        dic.Add('concurrency', tpConcurrency);
      {$IFNDEF FB_21UP}
        dic.Add('shared', tpShared);
        dic.Add('protected', tpProtected);
        dic.Add('exclusive', tpExclusive);
      {$ENDIF}
        dic.Add('wait', tpWait);
        dic.Add('nowait', tpNowait);
        dic.Add('read', tpRead);
        dic.Add('write', tpWrite);
        dic.Add('lockread', tpLockRead);
        dic.Add('lockwrite', tpLockWrite);
        dic.Add('verbtime', tpVerbTime);
        dic.Add('committime', tpCommitTime);
        dic.Add('ignorelimbo', tpIgnoreLimbo);
        dic.Add('readcommitted', tpReadCommitted);
        dic.Add('autocommit', tpAutoCommit);
        dic.Add('recversion', tpRecVersion);
        dic.Add('norecversion', tpNoRecVersion);
        dic.Add('restartrequests', tpRestartRequests);
        dic.Add('noautoundo', tpNoAutoUndo);
      {$IFDEF FB20_UP}
        dic.Add('locktimeout', tpLockTimeout);
      {$ENDIF}
        for obj in arr do
          if ObjectIsType(obj, stString) then
            if dic.TryGetValue(LowerCase(obj.AsString), prm) then
              Include(opt, prm);
      finally
        dic.Free;
      end;
{$IFDEF FB20_UP}
      if tpLockTimeout in opt then
        locktimeout := Options.I['locktimeout'];
{$ENDIF}
    end;
    if opt = [] then
      opt := [tpConcurrency, tpWait, tpWrite];

    params := CreateTRParams(opt, lockread, lockwrite{$IFDEF FB20_UP}, locktimeout{$ENDIF});
  end else
    params := '';

  if Length(Connections) = 1 then
  begin
    with Connections[0], FLibrary do
      TransactionStart(FTrHandle, FDbHandle, params);
  end
  else
  begin
    GetMem(buffer,  SizeOf(TISCTEB) * Length(Connections));
    try
    {$POINTERMATH ON}
      for i := 0 to Length(Connections) - 1 do
        with Buffer[i] do
        begin
          Handle  := @Connections[I].FDbHandle;
          Len     := Length(params);
          Address := PAnsiChar(params);
        end;
    {$POINTERMATH OFF}
      with Connections[0], FLibrary do
        TransactionStartMultiple(FTrHandle, Length(Connections), Buffer);
    finally
      FreeMem(Buffer);
    end
  end;
end;

destructor TDBUIBTransaction.Destroy;
begin
  with TDBUIBConnection(FConnection).FLibrary do
  if FRollback then
  begin
    TriggerRollbackEvent;
    TransactionRollback(FTrHandle);
  end else
  begin
    TransactionCommit(FTrHandle);
    TriggerCommitEvent;
  end;
  inherited Destroy;
end;

procedure TDBUIBTransaction.ExecuteImmediate(const Options: SOString);
begin
  with TDBUIBConnection(FConnection), FLibrary do
    DSQLExecuteImmediate(FDbHandle, FTrHandle, MBUEncode(Options, CharacterSetCP[FCharacterSet]), 3);
end;

function TDBUIBTransaction.Query(const Sql: string; const Connection: IDBConnection): IDBQuery;
begin
  if Connection = nil then
    Result := TDBUIBQuery.Create(FConnection, Self, Sql)
  else
    Result := TDBUIBQuery.Create(Connection, Self, Sql)
end;

{ TDBUIBQuery }

constructor TDBUIBQuery.Create(const Connection: IDBConnection;
  const Trans: TDBUIBTransaction; const Sql: string);
begin
  inherited Create;
  FConnection := Connection;
  FStHandle := nil;
  with TDBUIBConnection(Connection), FLibrary do
  begin
    FSQLResult := TSQLResult.Create(FCharacterSet, 0, False, True);
    FSQLParams := TSQLParams.Create(FCharacterSet);

    DSQLAllocateStatement(FDbHandle, FStHandle);
    try
      FStatementType := DSQLPrepare(FDbHandle, Trans.FTrHandle, FStHandle,
        MBUEncode(FSQLParams.Parse(PSOChar(Sql)), CharacterSetCP[FCharacterSet]), 3, FSQLResult);
    except
      on E: Exception do
      begin
        Trans.FRollback := True;
        raise;
      end;
    end;
    if (FSQLParams.FieldCount > 0) then
      DSQLDescribeBind(FStHandle, 3, FSQLParams);
  end;
end;

destructor TDBUIBQuery.Destroy;
begin
  FSQLResult.Free;
  FSQLParams.Free;
  TDBUIBConnection(FConnection).FLibrary.DSQLFreeStatement(FStHandle, DSQL_drop);
  inherited;
end;

function TDBUIBQuery.Execute(const Params: ISuperObject; Options: TQueryOptions;
  const Transaction: IDBTransaction): ISuperObject;
var
  //dfArray, dfSingleton, dfValue,
  NoCursor: boolean;
  str: string;
  ctx: IDBTransaction;

  function getone: ISuperObject;
    procedure SetValue(index: Integer; const value: ISuperObject);
    var
      str: string;
      v, a: ISuperObject;
    begin
      str := LowerCase(FSQLResult.AliasName[index]);
      if Result.AsObject.Find(str, v) then
        case ObjectGetType(v) of
          stArray: v.AsArray.Add(value);
        else
          a := TSuperObject.Create(stArray);
          a.AsArray.add(v);
          a.AsArray.add(value);
          Result[str] := a;
        end else
          Result[str] := value;
    end;

    function GetValue(index: Integer): ISuperObject;
    var
      blob: IDBBlob;
    begin
      if FSQLResult.IsNull[index] then
        Result := nil else
      case FSQLResult.FieldType[index] of
        uftChar, uftVarchar, uftCstring:
          if FSQLResult.Data.sqlvar[index].SqlSubType > 1 then
            Result := TSuperObject.Create(FSQLResult.AsString[index]) else
            Result := TSuperObject.Create(RbsToHex(FSQLResult.AsRawByteString[index]));
        uftSmallint, uftInteger, uftInt64: Result := TSuperObject.Create(FSQLResult.AsInt64[index]);
        uftNumeric:
          begin
            if FSQLResult.SQLScale[index] >= -4 then
              Result := TSuperObject.CreateCurrency(FSQLResult.AsCurrency[index]) else
              Result := TSuperObject.Create(FSQLResult.AsDouble[index]);
          end;
        uftFloat, uftDoublePrecision: Result := TSuperObject.Create(FSQLResult.AsDouble[index]);
        uftBlob, uftBlobId:
          begin
            if FSQLResult.Data^.sqlvar[index].SqlSubType = 1 then
            begin
              FSQLResult.ReadBlob(index, str);
              Result := TSuperObject.Create(str);
            end else
            begin
              blob := TDBBinary.Create;
              FSQLResult.ReadBlob(index, blob.getData);
              Result := blob as ISuperObject;
            end;
          end;
        uftTimestamp, uftDate, uftTime: Result := TDBDateTime.Create(DelphiToJavaDateTime(FSQLResult.AsDateTime[index]));
      {$IFDEF IB7_UP}
        uftBoolean: Result := TSuperObject.Create(PChar(FSQLResult.AsBoolean[index]));
      {$ENDIF}
       else
         Result := nil;
       end;
    end;

  var
    i: integer;
  begin
    if qoValue in Options then
    begin
      if FSQLResult.FieldCount > 0 then
        Result := GetValue(0) else
        Result := nil;
    end else
    if qoArray in Options then
    begin
      Result := TSuperObject.Create(stArray);
      for i := 0 to FSQLResult.FieldCount - 1 do
        Result.AsArray.Add(GetValue(i));
    end else
    begin
      Result := TSuperObject.Create(stObject);
      for i := 0 to FSQLResult.FieldCount - 1 do
        SetValue(i, GetValue(i));
    end;
  end;

  procedure SetParam(index: Integer; value: ISuperObject);
  var
    BlobHandle: IscBlobHandle;
    blob: IDBBlob;
    dt: TDateTime;
    i: Int64;
  begin
    if ObjectIsType(value, stNull) then
      FSQLParams.IsNull[index] := true else
      case FSQLParams.FieldType[index] of
        uftNumeric:
          begin
            if ObjectIsType(value, stCurrency) then
              FSQLParams.AsCurrency[index] := value.AsCurrency else
              FSQLParams.AsDouble[index] := value.AsDouble;
          end;
        uftChar, uftVarchar, uftCstring:
          if FSQLParams.Data.sqlvar[index].SqlSubType > 1 then
            FSQLParams.AsString[index] := value.AsString else
            FSQLParams.AsRawByteString[index] := HexToRbs(value.AsString);

        uftSmallint: FSQLParams.AsSmallint[index] := value.AsInteger;
        uftInteger: FSQLParams.AsInteger[index] := value.AsInteger;
        uftFloat: FSQLParams.AsSingle[index] := value.AsDouble;
        uftDoublePrecision: FSQLParams.AsDouble[index] := value.AsDouble;
        uftDate, uftTime, uftTimestamp:
          case ObjectGetType(value) of
            stInt: FSQLParams.AsDateTime[index] := JavaToDelphiDateTime(value.AsInteger);
            stString:
              if ISO8601DateToJavaDateTime(value.AsString, i) then
                FSQLParams.AsDateTime[index] := JavaToDelphiDateTime(i) else
                if TryStrToDateTime(value.AsString, dt) then
                  FSQLParams.AsDateTime[index] := dt else
                  FSQLParams.IsNull[index] := true;
          end;
        uftInt64: FSQLParams.AsInt64[index] := value.AsInteger;
        uftBlob, uftBlobId:
          with TDBUIBConnection(FConnection), FLibrary, TDBUIBTransaction(ctx) do
          begin
            BlobHandle := nil;
            FSQLParams.AsQuad[Index] := BlobCreate(FDbHandle, FTrHandle, BlobHandle);
            if value.QueryInterface(IDBBlob, blob) = 0 then
              BlobWriteStream(BlobHandle, blob.getData) else
              BlobWriteString(BlobHandle, MBUEncode(value.AsString, CharacterSetCP[FCharacterSet]));
            BlobClose(BlobHandle);
          end;
      else
        raise Exception.Create('not yet implemented');
      end;
  end;

  procedure Process;
  begin
    with TDBUIBConnection(FConnection), FLibrary, TDBUIBTransaction(ctx) do
      if FSQLResult.FieldCount > 0 then
      begin
        if not NoCursor then
          DSQLSetCursorName(FStHandle, AnsiChar('C') + AnsiString(IntToStr(PtrInt(FStHandle))));
        try
          if (FStatementType = stExecProcedure) then
          begin
            DSQLExecute2(FTrHandle, FStHandle, 3, FSQLParams, FSQLResult);
            Include(Options, qoSingleton);
          end else
            DSQLExecute(FTrHandle, FStHandle, 3, FSQLParams);

          if NoCursor then
            Result := getone else
          if not (qoSingleton in Options) then
          begin
            Result := TSuperObject.Create(stArray);
            while DSQLFetchWithBlobs(FDbHandle, FTrHandle, FStHandle, 3, FSQLResult) do
              Result.AsArray.Add(getone);
          end else
            if DSQLFetchWithBlobs(FDbHandle, FTrHandle, FStHandle, 3, FSQLResult) then
              Result := getone else
              Result := nil;
        finally
          if not NoCursor then
            DSQLFreeStatement(FStHandle, DSQL_close);
        end;
      end else
      begin
        DSQLExecute(FTrHandle, FStHandle, 3, FSQLParams);
        Result := TSuperObject.Create(DSQLInfoRowsAffected(FStHandle, FStatementType));
      end;
  end;
var
  j, affected: integer;
  f: TSuperObjectIter;
begin
  ctx := transaction;

  NoCursor := (qoSingleton in Options) and (FStatementType = stExecProcedure);

  if ctx = nil then
    ctx := FConnection.Transaction;

  for j := 0 to FSQLParams.FieldCount - 1 do
    FSQLParams.IsNull[j] := true;
  try
    if FSQLParams.FieldCount > 0 then
    begin
      if ObjectIsType(params, stArray) then
      begin
        with params.AsArray do
        begin
          if (Length = FSQLParams.FieldCount) and not(ObjectGetType(O[0]) in [stObject, stArray]) then
          begin
            for j := 0 to Length - 1 do
              SetParam(j, O[j]);
            Process;
          end else
            if FSQLResult.FieldCount > 0 then
            begin
              Result := TSuperObject.Create(stArray);
              for j := 0 to Length - 1 do
                Result.AsArray.Add(Execute(O[j], Options, ctx));
            end else
            begin
              affected := 0;
              for j := 0 to Length - 1 do
                inc(affected, Execute(O[j], Options, ctx).AsInteger);
              Result := TSuperObject.Create(affected);
            end;
        end;
      end else
      if ObjectIsType(params, stObject) then
      begin
        if ObjectFindFirst(params, f) then
        repeat
          SetParam(FSQLParams.GetFieldIndex(AnsiString(f.key)), f.val);
        until not ObjectFindNext(f);
        ObjectFindClose(f);
        Process;
      end else
      begin
        SetParam(0, params);
        Process;
      end;
    end else
      Process;
  except
    TDBUIBTransaction(ctx).FRollback := True;
    raise;
  end;
end;

function TDBUIBQuery.GetInputMeta: ISuperObject;
var
  j: Integer;
  rec: ISuperObject;
  prm: PUIBSQLVar;
begin
  if FSQLParams.FieldCount > 0 then
  begin
    Result := TSuperObject.Create(stArray);
    with Result.AsArray do
      for j := 0 to FSQLParams.FieldCount - 1 do
      begin
        rec := TSuperObject.Create(stObject);
        prm := @FSQLParams.Data.sqlvar[j];
        if prm.ParamNameLength > 0 then
          rec.S['name'] := LowerCase(string(copy(prm.ParamName, 1, prm.ParamNameLength)));
        add(rec);
        case FSQLParams.FieldType[j] of
          uftChar, uftVarchar, uftCstring:
          begin
            rec.S['type'] := 'str';
            rec.I['length'] := FSQLParams.SQLLen[j] div BytesPerCharacter[csUTF8];
          end;
          uftSmallint: rec.S['type'] := 'int16';
          uftInteger: rec.S['type'] := 'int32';
          uftInt64: rec.S['type'] := 'int64';
          uftNumeric:
            begin
              rec.S['type'] := 'numeric';
              rec.I['scale'] := -FSQLResult.SQLScale[j];
              case FSQLResult.SqlType[j] of
                SQL_SHORT:
                  if FSQLResult.SQLScale[j] = -4 then
                    rec.I['precision'] := 5 else
                    rec.I['precision'] := 4;
                SQL_LONG:
                  if FSQLResult.SQLScale[j] = -9 then
                    rec.I['precision'] := 10 else
                    rec.I['precision'] := 9;
                SQL_INT64:
                  if FSQLResult.SQLScale[j] = -18 then
                    rec.I['precision'] := 19 else
                    rec.I['precision'] := 18;
              end;
            end;

          uftFloat: rec.S['type'] := 'float';
          uftDoublePrecision: rec.S['type'] := 'double';
          uftBlob, uftBlobId:
          begin
            if FSQLParams.Data^.sqlvar[j].SqlSubType = 1 then
              rec.S['type'] := 'str' else
              rec.S['type'] := 'bin';
          end;
          uftTimestamp: rec.S['type'] := 'timestamp';
          uftDate: rec.S['type'] := 'date';
          uftTime: rec.S['type'] := 'time';
          {$IFDEF IB7_UP}
          uftBoolean: rec.S['type'] := 'bool';
          {$ENDIF}
        end;
        if not FSQLParams.IsNullable[j] then
          rec.B['notnull'] := true;
      end;
  end else
    Result := nil;
end;

function TDBUIBQuery.GetOutputMeta(byindex: Boolean): ISuperObject;
var
  j: Integer;
  rec: ISuperObject;
begin
  if FSQLResult.FieldCount > 0 then
  begin
    if byindex then
      Result := TSuperObject.Create(stArray) else
      Result := TSuperObject.Create(stObject);

      for j := 0 to FSQLResult.FieldCount - 1 do
      begin
        rec := TSuperObject.Create(stObject);
        if byindex then
        begin
          rec.S['name'] := LowerCase(FSQLResult.AliasName[j]);
          Result.asArray.add(rec);
        end else
          Result.AsObject[LowerCase(FSQLResult.AliasName[j])] := rec;

        case FSQLResult.FieldType[j] of
          uftChar, uftVarchar, uftCstring:
          begin
            rec.S['type'] := 'str';
            rec.I['length'] := FSQLResult.SQLLen[j] div BytesPerCharacter[csUTF8];
          end;
          uftSmallint: rec.S['type'] := 'int16';
          uftInteger: rec.S['type'] := 'int32';
          uftInt64: rec.S['type'] := 'int64';
          uftNumeric:
            begin
              rec.S['type'] := 'numeric';
              rec.I['scale'] := -FSQLResult.SQLScale[j];
              case FSQLResult.SqlType[j] of
                SQL_SHORT:
                  if FSQLResult.SQLScale[j] = -4 then
                    rec.I['precision'] := 5 else
                    rec.I['precision'] := 4;
                SQL_LONG:
                  if FSQLResult.SQLScale[j] = -9 then
                    rec.I['precision'] := 10 else
                    rec.I['precision'] := 9;
                SQL_INT64:
                  if FSQLResult.SQLScale[j] = -18 then
                    rec.I['precision'] := 19 else
                    rec.I['precision'] := 18;
              end;
            end;
          uftFloat: rec.S['type'] := 'float';
          uftDoublePrecision: rec.S['type'] := 'double';
          uftBlob, uftBlobId:
          begin
            if FSQLResult.Data^.sqlvar[j].SqlSubType = 1 then
              rec.S['type'] := 'str' else
              rec.S['type'] := 'bin';
          end;
          uftTimestamp: rec.S['type'] := 'timestamp';
          uftDate: rec.S['type'] := 'date';
          uftTime: rec.S['type'] := 'time';
          {$IFDEF IB7_UP}
          uftBoolean: rec.S['type'] := 'bool';
          {$ENDIF}
        end;
        if not FSQLResult.IsNullable[j] then
          rec.B['notnull'] := true;
      end;
  end else
    Result := nil;
end;

{ TDBUIBConnectionPool }

constructor TDBUIBConnectionPool.Create(max: Integer; const Database, Username,
  Password: string; const Characterset: string = 'UTF8'; const Lib: string = '');
begin
  inherited Create;
  FDatabase := Database;
  FUserName := Username;
  FPassword := Password;
  FCharacterset := Characterset;
  FLib := Lib;
  FPool := TList<IDBConnection>.Create;
  FCriticalSection := TCriticalSection.Create;
  FMax := max;
end;

procedure TDBUIBConnectionPool.ClearPool;
begin
  Lock;
  try
    FPool.Clear;
  finally
    Unlock;
  end;
end;

destructor TDBUIBConnectionPool.Destroy;
begin
  FCriticalSection.Free;
  FPool.Free;
  inherited;
end;

function TDBUIBConnectionPool.Connection: IDBConnection;
var
  cnx: IDBConnection;
  j, k: Integer;
begin
  Result := nil;

  Lock;
  try
    while Result = nil do
    begin
      for j := 0 to FPool.Count - 1 do
      begin
        cnx :=  FPool[j];
        k := cnx._AddRef;
        try
          if k = 3 then
          begin
            Result := cnx;
            Exit;
          end;
        finally
          cnx._Release;
          cnx := nil;
        end;
      end;
      if (Result = nil) and ((FMax < 1) or (FPool.Count < FMax)) then
      begin
        Result := TDBUIBConnection.Create(FDatabase, FUserName, FPassword, FCharacterset, FLib);
        FPool.Add(Result);
        Exit;
      end;
  {$IFDEF SWITCHTOTHREAD}
      if not SwitchToThread then
  {$ENDIF}
        Sleep(1);
    end;
  finally
    Unlock;
  end;
end;

function TDBUIBConnectionPool.Size: Integer;
begin
  Lock;
  try
    Result := FPool.Count;
  finally
    Unlock;
  end;
end;

procedure TDBUIBConnectionPool.Lock;
begin
  FCriticalSection.Enter;
end;

procedure TDBUIBConnectionPool.Unlock;
begin
  FCriticalSection.Leave;
end;

end.

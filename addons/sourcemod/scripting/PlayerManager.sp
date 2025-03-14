#include <ripext>
#include <sourcemod>
#include <basecomm>
#include <utilshelper>
#include <multicolors>

#undef REQUIRE_EXTENSIONS
#tryinclude <connect>
#define REQUIRE_EXTENSIONS

#undef REQUIRE_PLUGIN
#tryinclude <ProxyKiller>
#define REQUIRE_PLUGIN

#pragma semicolon 1
#pragma newdecls required

#define DATABASE_NAME		"player_manager"
#define DB_CHARSET			"utf8mb4"
#define DB_COLLATION		"utf8mb4_unicode_ci"
#define MAX_SQL_QUERY_LENGTH 1024

/* CONVARS */
ConVar g_hCvar_BlockVPN;
ConVar g_hCvar_AuthIdType;

bool g_bLate = false;

char sAuthID32[MAXPLAYERS + 1][64];
char sAuthID32Verified[MAXPLAYERS + 1][64];

#if defined _connect_included
ConVar g_hCvar_Log;
ConVar g_hCvar_BlockSpoof;
ConVar g_hCvar_BlockAdmin;
ConVar g_hCvar_BlockVoice;
ConVar g_hCvar_AuthSessionResponseLegal;
ConVar g_hCvar_AuthAntiSpoof;

/* DATABASE */
Handle g_hDatabase = null;

#define MAX_STEAMID_BUFFER 1024

/* STRING */
char g_cPlayerGUID[MAXPLAYERS + 1][40];
char g_sBeginAuthSessionFailed[MAX_STEAMID_BUFFER][64];
bool g_sBeginAuthSessionFailedDuplicate[MAX_STEAMID_BUFFER] = { false, ... };
char g_sAuthSessionReponseValidated[MAX_STEAMID_BUFFER][64];
EAuthSessionResponse g_eAuthSessionResponse[MAX_STEAMID_BUFFER] = { k_EAuthSessionResponseUserNotConnectedToSteam, ... };
bool g_bSteamLegal[MAX_STEAMID_BUFFER] = { false, ... };

bool g_bSQLite = true;
#endif

enum BlockVPN
{
	vpn_Disable = 0,
	vpn_Everyone = 1,
	vpn_NoSteam = 2,
	vpn_Steam = 3,
}

enum ConnectionType
{
	ct_NoSteam = 0,
	ct_Steam = 1,
}

public Plugin myinfo =
{
	name         = "PlayerManager",
	author       = "zaCade, Neon, maxime1907, .Rushaway",
	description  = "Manage clients, block spoofers...",
	version      = "2.2.9"
};

public APLRes AskPluginLoad2(Handle hMyself, bool bLate, char[] sError, int errorSize)
{
	CreateNative("PM_IsPlayerSteam", Native_IsPlayerSteam);
#if defined _connect_included
	CreateNative("PM_GetPlayerType", Native_GetPlayerType);
	CreateNative("PM_GetPlayerGUID", Native_GetPlayerGUID);
#endif
	RegPluginLibrary("PlayerManager");

	g_bLate = bLate;
	return APLRes_Success;
}

public void OnPluginStart()
{
	LoadTranslations("common.phrases");

#if defined _connect_included
	g_hCvar_BlockVPN = CreateConVar("sm_manager_block_vpn", "2", "3 = block steam, 2 = block nosteam, 1 = block everyone, 0 = disable.", FCVAR_NONE, true, 0.0, true, 3.0);
	g_hCvar_BlockSpoof = CreateConVar("sm_manager_block_spoof", "1", "Kick unauthenticated people that join with known steamids.", FCVAR_NONE, true, 0.0, true, 1.0);
	g_hCvar_BlockAdmin = CreateConVar("sm_manager_block_admin", "1", "Block unauthenticated people from being admin", FCVAR_NONE, true, 0.0, true, 1.0);
	g_hCvar_BlockVoice = CreateConVar("sm_manager_block_voice", "1", "Block unauthenticated people from voice chat", FCVAR_NONE, true, 0.0, true, 1.0);
	g_hCvar_AuthSessionResponseLegal = CreateConVar("sm_manager_auth_session_response_legal", "0,3,4,5,9", "List of EAuthSessionResponse that are considered as Steam legal (Defined in steam_api_interop.cs).");
	g_hCvar_AuthAntiSpoof = CreateConVar("sm_manager_auth_antispoof", "1", "0 = Disable, 1 = Prevent steam users to be spoofed by nosteamers, 2 = 1 + reject incoming same nosteam id");
	g_hCvar_Log = CreateConVar("sm_manager_log", "0", "Log a bunch of checks.", FCVAR_NONE, true, 0.0, true, 1.0);
#else
	g_hCvar_BlockVPN = CreateConVar("sm_manager_block_vpn", "0", "1 = block everyone, 0 = disable.", FCVAR_NONE, true, 0.0, true, 1.0);
#endif

	g_hCvar_AuthIdType = CreateConVar("sm_manager_authid_type", "1", "AuthID type used for sm_steamid cmd [0 = Engine, 1 = Steam2, 2 = Steam3, 3 = Steam64]", FCVAR_NONE, true, 0.0, true, 3.0);

	HookEvent("player_disconnect", Event_ClientDisconnect, EventHookMode_Pre);

	RegConsoleCmd("sm_steamid", Command_SteamID, "Retrieves your Steam ID");
	RegConsoleCmd("sm_auth", Command_GetAuth, "Retrieves the Steam ID of a player");

	#if defined _connect_included
	RegAdminCmd("sm_authlist", Command_GetAuthList, ADMFLAG_GENERIC, "List auth id buffer list");
	#endif

	AutoExecConfig(true);

	if (g_bLate)
	{
		char sSteam32ID[32];
		for (int i = 1; i < MaxClients; i++)
		{
			if (IsClientInGame(i) && !IsFakeClient(i) && IsClientAuthorized(i) && GetClientAuthId(i, AuthId_Steam2, sSteam32ID, sizeof(sSteam32ID)))
				OnClientAuthorized(i, sSteam32ID);
		}
	}
}

public void Event_ClientDisconnect(Handle event, const char[] name, bool dontBroadcast)
{
	int userid = GetEventInt(event, "userid");
	int client = GetClientOfUserId(userid);

	if (g_hCvar_Log.BoolValue)
		LogMessage("Event_ClientDisconnect %d", client);

	#if defined _connect_included
	int index = FindStringInList(g_sBeginAuthSessionFailed, sizeof(g_sBeginAuthSessionFailed), sAuthID32[client]);
	if (index != -1)
	{
		if (g_hCvar_Log.BoolValue)
			LogMessage("OnClientDisconnect g_sBeginAuthSessionFailed[%d][%s]: duplicate(%d)", index, g_sBeginAuthSessionFailed[index], g_sBeginAuthSessionFailedDuplicate[index]);
		g_sBeginAuthSessionFailed[index] = "\0";
		g_sBeginAuthSessionFailedDuplicate[index] = false;
	}

	index = FindStringInList(g_sAuthSessionReponseValidated, sizeof(g_sAuthSessionReponseValidated), sAuthID32[client]);
	if (index != -1)
	{
		if (g_hCvar_Log.BoolValue)
			LogMessage("OnClientDisconnect g_sAuthSessionReponseValidated[index](%s) response(%d) legal(%d)", g_sAuthSessionReponseValidated[index], g_eAuthSessionResponse[index], g_bSteamLegal[index]);
		g_sAuthSessionReponseValidated[index][0] = '\0';
		g_eAuthSessionResponse[index] = k_EAuthSessionResponseUserNotConnectedToSteam;
		g_bSteamLegal[index] = false;
	}
	#endif

	FormatEx(sAuthID32[client], sizeof(sAuthID32[]), "");
	FormatEx(sAuthID32Verified[client], sizeof(sAuthID32Verified[]), "");
}

#if defined _connect_included
public void OnConfigsExecuted()
{
	if(!g_hCvar_BlockSpoof.BoolValue)
		return;

	if (g_hDatabase != null)
		delete g_hDatabase;

	if (SQL_CheckConfig(DATABASE_NAME))
		SQL_TConnect(OnSQLConnected, DATABASE_NAME);
	else
		SetFailState("Could not find \"%s\" entry in databases.cfg.", DATABASE_NAME);
}
#endif

public void OnClientAuthorized(int client, const char[] sAuthID)
{
	char sSteamIDVerified[64];
	GetClientAuthId(client, AuthId_Steam2, sSteamIDVerified, sizeof(sSteamIDVerified));

	FormatEx(sAuthID32Verified[client], sizeof(sAuthID32Verified[]), "%s", sSteamIDVerified);

#if defined _connect_included
	if (!g_hCvar_BlockSpoof.BoolValue
	|| !g_hDatabase || IsFakeClient(client) || IsClientSourceTV(client)
	|| !SteamClientGotValidateAuthTicketResponse(sAuthID))
		return;

	char sAddress[16];
	GetClientIP(client, sAddress, sizeof(sAddress));

	int iConnectionType;
	if (SteamClientAuthenticated(sAuthID))
		iConnectionType = view_as<int>(ct_Steam);
	else
		iConnectionType = view_as<int>(ct_NoSteam);

	DataPack pack = new DataPack();
	pack.WriteCell(client);
	pack.WriteString(sAuthID);
	pack.WriteString(sAddress);
	pack.WriteCell(iConnectionType);

	SQLSelect_Connection(pack);
#endif
}

#if defined _connect_included
public Action OnClientPreAdminCheck(int client)
{
	if(!g_hCvar_BlockAdmin.BoolValue || IsFakeClient(client) || IsClientSourceTV(client))
		return Plugin_Continue;

	if (SteamClientGotValidateAuthTicketResponse(sAuthID32[client]) && !SteamClientAuthenticated(sAuthID32[client]))
	{
		LogMessage("%L was not authenticated with steam, denying admin.", client);
		NotifyPostAdminCheck(client);
		return Plugin_Handled;
	}

	return Plugin_Continue;
}

public void OnClientPostAdminCheck(int client)
{
	if (!g_hCvar_BlockVoice.BoolValue || IsFakeClient(client) || IsClientSourceTV(client))
		return;

	if(SteamClientGotValidateAuthTicketResponse(sAuthID32[client]) && !SteamClientAuthenticated(sAuthID32[client]))
	{
		LogMessage("%L was not authenticated with steam, muting client.", client);
		BaseComm_SetClientMute(client, true);
		return;
	}
}

int GetSpooferClient(const char[] steamID)
{
	int connectedclient = -1;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientConnected(i))
		{
			char sSteamID[64];
			GetClientAuthId(i, AuthId_Steam2, sSteamID, sizeof(sSteamID), false);
			if (StrEqual(sSteamID, steamID, false))
			{
				connectedclient = i;
				break;
			}
		}
	}
	return connectedclient;
}

bool IsIncomingClientSpoofing(const char[] steamID, bool bSteamLegal)
{
	int client = FindStringInList(g_sAuthSessionReponseValidated, sizeof(g_sAuthSessionReponseValidated), steamID);
	if (client == -1)
		return false;

	return (
		// Incoming steam player trying to spoof NoSteamer
		(bSteamLegal && !g_bSteamLegal[client] && g_hCvar_AuthAntiSpoof.IntValue < 1)
		// Incoming NoSteam player trying to spoof steam player
		|| (!bSteamLegal && g_bSteamLegal[client] && g_hCvar_AuthAntiSpoof.IntValue >= 1)
		// Incoming NoSteam player trying to spoof NoSteam player
		|| (g_hCvar_AuthAntiSpoof.IntValue >= 2 && !bSteamLegal && !g_bSteamLegal[client])
	);
}

public EBeginAuthSessionResult OnBeginAuthSessionResult(const char[] steamID, EBeginAuthSessionResult eBeginAuthSessionResult)
{
	if (g_hCvar_Log.BoolValue)
		LogMessage("OnBeginAuthSessionResult[%s]: result(%d)", steamID, eBeginAuthSessionResult);

	if (eBeginAuthSessionResult == k_EBeginAuthSessionResultInvalidTicket)
	{
		int index = FindStringInList(g_sBeginAuthSessionFailed, sizeof(g_sBeginAuthSessionFailed), steamID);
		if (index != -1)
		{
			LogMessage("Duplicate begin auth session entry for %s", steamID);
			g_sBeginAuthSessionFailedDuplicate[index] = true;
		}
		else
		{
			int client = 0;
			while (client < sizeof(g_sBeginAuthSessionFailed))
			{
				if (g_sBeginAuthSessionFailed[client][0] == '\0')
					break;
				client++;
			}
			if (client >= sizeof(g_sBeginAuthSessionFailed))
				LogError("Buffer g_sBeginAuthSessionFailed is full");
			else
				strcopy(g_sBeginAuthSessionFailed[client], sizeof(g_sBeginAuthSessionFailed[]), steamID);
		}
		return k_EBeginAuthSessionResultOK;
	}
	return eBeginAuthSessionResult;
}

public bool OnClientPreConnectEx(const char[] name, char password[255], const char[] ip, const char[] steamID, char rejectReason[255])
{
	if (g_hCvar_Log.BoolValue)
		LogMessage("OnClientPreConnectEx %s", steamID);

	int index = FindStringInList(g_sBeginAuthSessionFailed, sizeof(g_sBeginAuthSessionFailed), steamID);
	int spooferclient = GetSpooferClient(steamID);
	if (index != -1 && spooferclient != -1)
	{
		bool bSteamLegal = g_sBeginAuthSessionFailedDuplicate[index] ? false : !g_bSteamLegal[index];
		if (g_hCvar_Log.BoolValue)
			LogMessage("OnClientPreConnectEx[%s]: legal(%d)", steamID, bSteamLegal);

		if (IsIncomingClientSpoofing(steamID, bSteamLegal))
		{
			LogMessage("[%s] Kicking incoming spoofer client", steamID);
			Format(rejectReason, sizeof(rejectReason), "Steam ID already in use on server");
			return false;
		}
		else
		{
			if (spooferclient != -1)
			{
				LogMessage("[%s] Kicking spoofer client", steamID);
				KickClientEx(spooferclient, "Same Steam ID connected.");
				OnBeginAuthSessionResult(steamID, k_EBeginAuthSessionResultInvalidTicket);
			}
			else
			{
				LogError("[%s] Unable to find spoofer client index", steamID);
				Format(rejectReason, sizeof(rejectReason), "Unexpected connection error, please try again");
				return false;
			}
		}
	}
	return true;
}

public void OnClientConnected(int client)
{
	if (g_hCvar_Log.BoolValue)
		LogMessage("OnClientConnected %L", client);

	char sSteamID[64];
	GetClientAuthId(client, AuthId_Steam2, sSteamID, sizeof(sSteamID), false);

	FormatEx(sAuthID32[client], sizeof(sAuthID32[]), "%s", sSteamID);

	int index = FindStringInList(g_sBeginAuthSessionFailed, sizeof(g_sBeginAuthSessionFailed), sSteamID);
	if (index != -1 && !SteamClientGotValidateAuthTicketResponse(sAuthID32[client]))
	{
		char sSteamID64[128];
		GetClientAuthId(client, AuthId_SteamID64, sSteamID64, sizeof(sSteamID64), false);
		ValidateAuthTicketResponse(sSteamID64, k_EAuthSessionResponseAuthTicketInvalid, sSteamID64);
	}
}

public EAuthSessionResponse OnValidateAuthTicketResponse(const char[] steamID, EAuthSessionResponse eAuthSessionResponse)
{
	bool bSteamLegal = IsAuthSessionResponseSteamLegal(eAuthSessionResponse);

	if (g_hCvar_Log.BoolValue)
		LogMessage("OnValidateAuthTicketResponse[%s]: response(%d), legal(%d)", steamID, eAuthSessionResponse, bSteamLegal);

	int client = 0;
	while (client < sizeof(g_sAuthSessionReponseValidated))
	{
		if (g_sAuthSessionReponseValidated[client][0] == '\0')
			break;
		client++;
	}
	if (client >= sizeof(g_sAuthSessionReponseValidated))
		LogError("Buffer g_sAuthSessionReponseValidated is full");
	else
	{
		strcopy(g_sAuthSessionReponseValidated[client], sizeof(g_sAuthSessionReponseValidated[]), steamID);
		g_eAuthSessionResponse[client] = eAuthSessionResponse;
		g_bSteamLegal[client] = bSteamLegal;
	}

	return bSteamLegal ? k_EAuthSessionResponseOK : eAuthSessionResponse;
}

bool IsAuthSessionResponseSteamLegal(EAuthSessionResponse eAuthSessionResponse)
{
	char authString[128];
	g_hCvar_AuthSessionResponseLegal.GetString(authString, sizeof(authString));

	char legalAuthSessionResponse[10][128];
	int legalAuthSessionResponseCount = ExplodeString(authString, ",", legalAuthSessionResponse, sizeof(legalAuthSessionResponse), sizeof(legalAuthSessionResponse[]));

	for (int i = 0; i < legalAuthSessionResponseCount; i++)
	{
		EAuthSessionResponse eLegalAuthSessionResponse = view_as<EAuthSessionResponse>(StringToInt(legalAuthSessionResponse[i]));
		if (eAuthSessionResponse == eLegalAuthSessionResponse)
			return true;
	}

	return false;
}

bool SteamClientAuthenticated(const char[] steamID)
{
	int client = FindStringInList(g_sAuthSessionReponseValidated, sizeof(g_sAuthSessionReponseValidated), steamID);
	return client != -1 ? g_bSteamLegal[client]: false;
}

bool SteamClientGotValidateAuthTicketResponse(const char[] steamID)
{
	return FindStringInList(g_sAuthSessionReponseValidated, sizeof(g_sAuthSessionReponseValidated), steamID) != -1;
}

int FindStringInList(const char[][] array, int arraySize, const char[] searchString)
{
	for (int i = 0; i < arraySize; i++)
	{
		if (StrEqual(array[i], searchString))
		{
			return i;
		}
	}

	return -1;
}
#endif

#if defined _ProxyKiller_included_
public Action ProxyKiller_DoCheckClient(int client)
{
	if (g_hCvar_BlockVPN.IntValue <= view_as<int>(vpn_Disable))
		return Plugin_Handled;

	if (g_hCvar_BlockVPN.IntValue == view_as<int>(vpn_Everyone))
		return Plugin_Continue;

#if defined _connect_included
	if (SteamClientGotValidateAuthTicketResponse(sAuthID32[client]))
	{
		if (SteamClientAuthenticated(sAuthID32[client]))
		{
			if (g_hCvar_BlockVPN.IntValue == view_as<int>(vpn_Steam))
				return Plugin_Continue;
		}
		else
		{
			if (g_hCvar_BlockVPN.IntValue == view_as<int>(vpn_NoSteam))
				return Plugin_Continue;
		}
	}
	else if (g_hCvar_Log.BoolValue)
	{
		LogMessage("ProxyKiller: Validate auth ticket response not received for client %L", client);
	}
#endif
	return Plugin_Handled;
}
#endif

//   .d8888b.   .d88888b.  888b     d888 888b     d888        d8888 888b    888 8888888b.   .d8888b.
//  d88P  Y88b d88P" "Y88b 8888b   d8888 8888b   d8888       d88888 8888b   888 888  "Y88b d88P  Y88b
//  888    888 888     888 88888b.d88888 88888b.d88888      d88P888 88888b  888 888    888 Y88b.
//  888        888     888 888Y88888P888 888Y88888P888     d88P 888 888Y88b 888 888    888  "Y888b.
//  888        888     888 888 Y888P 888 888 Y888P 888    d88P  888 888 Y88b888 888    888     "Y88b.
//  888    888 888     888 888  Y8P  888 888  Y8P  888   d88P   888 888  Y88888 888    888       "888
//  Y88b  d88P Y88b. .d88P 888   "   888 888   "   888  d8888888888 888   Y8888 888  .d88P Y88b  d88P
//   "Y8888P"   "Y88888P"  888       888 888       888 d88P     888 888    Y888 8888888P"   "Y8888P"
//

#if defined _connect_included
public Action Command_GetAuthList(int client, int args)
{
	for (int index = 0; index < sizeof(g_sAuthSessionReponseValidated[]); index++)
	{
		if (g_sAuthSessionReponseValidated[index][0] != '\0')
		{
			CReplyToCommand(client, "Client[%s]: response(%d), legal(%d)", g_sAuthSessionReponseValidated[index], g_eAuthSessionResponse[index], g_bSteamLegal[index]);
		}
	}
	return Plugin_Handled;
}
#endif

public Action Command_GetAuth(int client, int args)
{
	int iTarget = client;
	int iType = g_hCvar_AuthIdType.IntValue;

	if (args == 0)
	{
		CReplyToCommand(client, "{green}[SM] {default}Usage: {olive}sm_auth <target> <0|1|2|3>");
		return Plugin_Handled;
	}

	SetGlobalTransTarget(client);

	if (args != 0)
	{
		char sArg[MAX_NAME_LENGTH];
		char sArg2[8];

		GetCmdArg(1, sArg, sizeof(sArg));
		iTarget = FindTarget(client, sArg, false, true);

		if (args == 2)
		{
			GetCmdArg(2, sArg2, sizeof(sArg2));
			iType = StringToInt(sArg2);
		}
	}

	if (iTarget < 1 || iTarget > MaxClients)
	{
		CReplyToCommand(client, "{green}[SM] {default}%t", "Player no longer available");
		return Plugin_Handled;
	}

	char sAuthID[64];
	char sBuffer[64];
	GetFormattedAuthId(iTarget, view_as<AuthIdType>(iType), sAuthID, sizeof(sAuthID), sBuffer, sizeof(sBuffer));

	if (iTarget == client)
		CReplyToCommand(client, "{green}[SM] {olive}%N{default}, your %s ID is: {blue}%s", client, sBuffer, sAuthID);
	else
		CReplyToCommand(client, "{green}[SM] {default}%s ID for player {olive}%N {default}is: {blue}%s", sBuffer, iTarget, sAuthID);

	return Plugin_Handled;
}
public Action Command_SteamID(int client, int args)
{
	char sAuthID[64];
	char sBuffer[64];
	GetFormattedAuthId(client, view_as<AuthIdType>(g_hCvar_AuthIdType.IntValue), sAuthID, sizeof(sAuthID), sBuffer, sizeof(sBuffer));

	CReplyToCommand(client, "{green}[SM] {olive}%N{default}, your %s ID is: {blue}%s", client, sBuffer, sAuthID);

	return Plugin_Handled;
}

stock void GetFormattedAuthId(int client, AuthIdType authType, char[] sAuthID, int maxlen, char[] sBufferType, int typeMaxLen)
{
	GetClientAuthId(client, authType, sAuthID, maxlen);
	switch(authType)
	{
		case AuthId_Engine:
			strcopy(sBufferType, typeMaxLen, "Steam(Engine)");
		case AuthId_Steam3:
			strcopy(sBufferType, typeMaxLen, "Steam(3)");
		case AuthId_SteamID64:
			strcopy(sBufferType, typeMaxLen, "Steam(64)");
		default:
			strcopy(sBufferType, typeMaxLen, "Steam(2)");
	}
}

#if defined _connect_included
stock void OnSQLConnected(Handle hParent, Handle hChild, const char[] err, any data)
{
	if (hChild == null)
	{
		LogError("Failed to connect to database \"%s\". (%s)", DATABASE_NAME, err);
		return;
	}

	char sDriver[16];
	g_hDatabase = CloneHandle(hChild);
	SQL_GetDriverIdent(hParent, sDriver, sizeof(sDriver));

	SQL_LockDatabase(g_hDatabase);

	if (!strncmp(sDriver, "my", 2, false))
		g_bSQLite = false;
	else
		g_bSQLite = true;

	SQLSetNames();

	SQLTableCreation_Connection();

	SQL_UnlockDatabase(g_hDatabase);
}

stock void SQLSetNames()
{
	if (!g_bSQLite)
	{
		char sQuery[MAX_SQL_QUERY_LENGTH];
		Format(sQuery, sizeof(sQuery), "SET NAMES \"%s\"", DB_CHARSET);
		SQL_TQuery(g_hDatabase, OnSqlSetNames, sQuery);
	}
}

stock void OnSqlSetNames(Handle hParent, Handle hChild, const char[] err, any data)
{
	if (hChild == null)
	{
		LogError("Database error while setting names as utf8. (%s)", err);
		return;
	}
}

stock void SQLTableCreation_Connection()
{
	char sQuery[MAX_SQL_QUERY_LENGTH];
	if (g_bSQLite)
		Format(sQuery, sizeof(sQuery), "CREATE TABLE IF NOT EXISTS connection (`auth` TEXT NOT NULL, `type` INTEGER(2) NOT NULL, `address` VARCHAR(16) NOT NULL, `timestamp` INTEGER(32) NOT NULL, PRIMARY KEY (`auth`)) CHARACTER SET %s COLLATE %s;", DB_CHARSET, DB_COLLATION);
	else
		Format(sQuery, sizeof(sQuery), "CREATE TABLE IF NOT EXISTS connection (`auth` VARCHAR(32) NOT NULL, `type` INT(2) NOT NULL, `address` VARCHAR(16) NOT NULL, `timestamp` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY (`auth`)) CHARACTER SET %s COLLATE %s;", DB_CHARSET, DB_COLLATION);

	SQL_TQuery(g_hDatabase, OnSQLTableCreated_Connection, sQuery);
}

public void OnSQLTableCreated_Connection(Handle hParent, Handle hChild, const char[] err, any data)
{
	if (hChild == null)
	{
		LogError("Database error while creating/checking for \"connection\" table. (%s)", DATABASE_NAME, err);
		return;
	}
}

stock Action SQLSelect_Connection(any data)
{
	if (g_hDatabase == null)
		return Plugin_Stop;

	DataPack pack = view_as<DataPack>(data);
	pack.Reset();

	char sAuthID[32];

	pack.ReadCell();
	pack.ReadString(sAuthID, sizeof(sAuthID));

	char sQuery[512];
	Format(sQuery, sizeof(sQuery), "SELECT `auth`, `type`, `address` FROM connection WHERE auth='%s'", sAuthID);

	SQL_TQuery(g_hDatabase, OnSQLSelect_Connection, sQuery, data, DBPrio_Low);
	return Plugin_Stop;
}

stock Action SQLInsert_Connection(any data)
{
	if (g_hDatabase == null)
		return Plugin_Stop;

	DataPack pack = view_as<DataPack>(data);
	pack.Reset();

	char sAuthID[32];
	char sAddress[16];

	pack.ReadCell();
	pack.ReadString(sAuthID, sizeof(sAuthID));
	pack.ReadString(sAddress, sizeof(sAddress));
	int iType = pack.ReadCell();

	char sQuery[512];
	Format(sQuery, sizeof(sQuery), "INSERT INTO connection (auth, type, address) VALUES ('%s', '%d', '%s') ON DUPLICATE KEY UPDATE type='%d', address='%s';", sAuthID, iType, sAddress, iType, sAddress);

	SQL_TQuery(g_hDatabase, OnSQLInsert_Connection, sQuery, data, DBPrio_Low);
	return Plugin_Stop;
}

stock void OnSQLSelect_Connection(Handle hParent, Handle hChild, const char[] err, any data)
{
	DataPack pack = view_as<DataPack>(data);
	pack.Reset();

	char sAuthID[32];
	char sAddress[16];

	int client = pack.ReadCell();
	pack.ReadString(sAuthID, sizeof(sAuthID));
	pack.ReadString(sAddress, sizeof(sAddress));
	int type = pack.ReadCell();

	if (hChild == null)
	{
		LogError("An error occurred while querying the database for connection details. (%s)", err);
		delete pack;
		return;
	}
	else if (SQL_FetchRow(hChild))
	{
		char sResultAuthID[32];
		char sResultAddress[16];
		int iResultType;

		SQL_FetchString(hChild, 0, sResultAuthID, sizeof(sResultAuthID));
		iResultType = SQL_FetchInt(hChild, 1);
		SQL_FetchString(hChild, 2, sResultAddress, sizeof(sResultAddress));

		if (type == view_as<int>(ct_NoSteam) && iResultType == view_as<int>(ct_Steam))
		{
			if (StrEqual(sAddress, sResultAddress, false))
			{
				LogMessage("%L tried to join with a legitimate steamid while not authenticated with steam. Allowing connection, IPs match. (Known: %s)", client, sAddress);
			}
			else
			{
				LogAction(client, -1, "\"%L\" tried to join with a legitimate steamid while not authenticated with steam. Refusing connection, IPs dont match. (Known: %s | Current: %s)", client, sResultAddress, sAddress);
				KickClient(client, "Trying to join with a legitimate steamid while not authenticated with steam.");
			}
			delete pack;
			return;
		}
	}

	SQLInsert_Connection(data);
}

public void OnSQLInsert_Connection(Handle hParent, Handle hChild, const char[] err, any data)
{
	DataPack pack = view_as<DataPack>(data);
	pack.Reset();

	if (hChild == null)
	{
		LogError("An error occurred while inserting a connection. (%s)", err);
	}

	delete pack;
}

stock void LogPotentialSpoofer(int client)
{
	if (IsFakeClient(client) || !IsClientConnected(client))
		return;

	char sSteam64ID[32];
	Steam32IDtoSteam64ID(sAuthID32[client], sSteam64ID, sizeof(sSteam64ID));

	char sSteamAPIKey[64];
	GetSteamAPIKey(sSteamAPIKey, sizeof(sSteamAPIKey));

	static char sRequest[256];
	FormatEx(sRequest, sizeof(sRequest), "http://api.steampowered.com/ISteamUser/GetPlayerSummaries/v0002/?key=%s&steamids=%s&format=json", sSteamAPIKey, sSteam64ID);

	HTTPRequest request = new HTTPRequest(sRequest);

	request.Get(OnPlayerSummaryReceived, client);
}

void OnPlayerSummaryReceived(HTTPResponse response, any client)
{
	if (response.Status != HTTPStatus_OK)
		return;

	// Indicate that the response contains a JSON object
	JSONObject responseData = view_as<JSONObject>(response.Data);

	JSONObject responseJSON = view_as<JSONObject>(responseData.Get("response"));

	APIWebResponse(responseJSON, client);
}

public void APIWebResponse(JSONObject responseJSON, int client)
{
	// No friends or private profile
	if (!responseJSON.Size)
	{
		delete responseJSON;
		return;
	}

	JSONArray players = view_as<JSONArray>(responseJSON.Get("players"));

	if (!players.Length)
	{
		delete players;
		delete responseJSON;
		return;
	}

	if (IsClientConnected(client) && !SteamClientAuthenticated(sAuthID32Verified[client]))
	{
		LogMessage("Potential spoofer %N %s", client, sAuthID32Verified[client]);
	}

	delete players;
	delete responseJSON;
}

//  888b    888        d8888 88888888888 8888888 888     888 8888888888 .d8888b.
//  8888b   888       d88888     888       888   888     888 888       d88P  Y88b
//  88888b  888      d88P888     888       888   888     888 888       Y88b.
//  888Y88b 888     d88P 888     888       888   Y88b   d88P 8888888    "Y888b.
//  888 Y88b888    d88P  888     888       888    Y88b d88P  888           "Y88b.
//  888  Y88888   d88P   888     888       888     Y88o88P   888             "888
//  888   Y8888  d8888888888     888       888      Y888P    888       Y88b  d88P
//  888    Y888 d88P     888     888     8888888     Y8P     8888888888 "Y8888P"

public int Native_GetPlayerType(Handle hPlugin, int numParams)
{
	int client = GetNativeCell(1);

	if (client < 1 || client > MaxClients)
	{
		return ThrowNativeError(SP_ERROR_NATIVE, "Client index %d is invalid", client);
	}
	else if (!IsClientConnected(client))
	{
		return ThrowNativeError(SP_ERROR_NATIVE, "Client %d is not connected", client);
	}
	else if (IsFakeClient(client))
	{
		return ThrowNativeError(SP_ERROR_NATIVE, "Client %d is a bot", client);
	}

	if (SteamClientAuthenticated(sAuthID32[client]))
		SetNativeCellRef(2, 1);
	else
		SetNativeCellRef(2, 0);

	SetNativeCellRef(2, 0);
	return 1;
}

public int Native_GetPlayerGUID(Handle hPlugin, int numParams)
{
	int client = GetNativeCell(1);
	int length = GetNativeCell(3);

	if (client < 1 || client > MaxClients)
	{
		return ThrowNativeError(SP_ERROR_NATIVE, "Client index %d is invalid", client);
	}
	else if (!IsClientConnected(client))
	{
		return ThrowNativeError(SP_ERROR_NATIVE, "Client %d is not connected", client);
	}
	else if (IsFakeClient(client))
	{
		return ThrowNativeError(SP_ERROR_NATIVE, "Client %d is a bot", client);
	}

	return !SetNativeString(2, g_cPlayerGUID[client], length + 1);
}
#endif

public int Native_IsPlayerSteam(Handle hPlugin, int numParams)
{
	int client = GetNativeCell(1);

	if (client < 1 || client > MaxClients)
	{
		return ThrowNativeError(SP_ERROR_NATIVE, "Client index %d is invalid", client);
	}
	else if (!IsClientConnected(client))
	{
		return ThrowNativeError(SP_ERROR_NATIVE, "Client %d is not connected", client);
	}
	else if (IsFakeClient(client))
	{
		return ThrowNativeError(SP_ERROR_NATIVE, "Client %d is a bot", client);
	}

#if defined _connect_included
	if (SteamClientAuthenticated(sAuthID32[client]))
		return 1;

	return 0;
#else
	return 1;
#endif
}

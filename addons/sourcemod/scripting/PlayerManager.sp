#include <ripext>
#include <sourcemod>
#include <basecomm>
#include <utilshelper>
#include <multicolors>

#undef REQUIRE_EXTENSIONS
#tryinclude <connect>
#define REQUIRE_EXTENSIONS

#undef REQUIRE_PLUGINS
#tryinclude <ProxyKiller>
#define REQUIRE_PLUGINS

#pragma semicolon 1
#pragma newdecls required

#define DATABASE_NAME					"player_manager"

/* CONVARS */
ConVar g_hCvar_Log;
ConVar g_hCvar_BlockVPN;

char sAuthID32[MAXPLAYERS + 1][64];
char sAuthID32Verified[MAXPLAYERS + 1][64];

#if defined _Connect_Included
ConVar g_hCvar_BlockSpoof;
ConVar g_hCvar_BlockAdmin;
ConVar g_hCvar_BlockVoice;

/* DATABASE */
Handle g_hDatabase = null;

/* STRING */
char g_cPlayerGUID[MAXPLAYERS + 1][40];

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
	version      = "2.2.3"
};

public APLRes AskPluginLoad2(Handle hMyself, bool bLate, char[] sError, int errorSize)
{
	CreateNative("PM_IsPlayerSteam", Native_IsPlayerSteam);
#if defined _Connect_Included
	CreateNative("PM_GetPlayerType", Native_GetPlayerType);
	CreateNative("PM_GetPlayerGUID", Native_GetPlayerGUID);
#endif
	RegPluginLibrary("PlayerManager");
	return APLRes_Success;
}

public void OnPluginStart()
{
	LoadTranslations("common.phrases");

#if defined _Connect_Included
	g_hCvar_BlockVPN = CreateConVar("sm_manager_block_vpn", "2", "3 = block steam, 2 = block nosteam, 1 = block everyone, 0 = disable.", FCVAR_NONE, true, 0.0, true, 3.0);
	g_hCvar_BlockSpoof = CreateConVar("sm_manager_block_spoof", "1", "Kick unauthenticated people that join with known steamids.", FCVAR_NONE, true, 0.0, true, 1.0);
	g_hCvar_BlockAdmin = CreateConVar("sm_manager_block_admin", "1", "Block unauthenticated people from being admin", FCVAR_NONE, true, 0.0, true, 1.0);
	g_hCvar_BlockVoice = CreateConVar("sm_manager_block_voice", "1", "Block unauthenticated people from voice chat", FCVAR_NONE, true, 0.0, true, 1.0);
#else
	g_hCvar_BlockVPN = CreateConVar("sm_manager_block_vpn", "0", "1 = block everyone, 0 = disable.", FCVAR_NONE, true, 0.0, true, 1.0);
#endif

	g_hCvar_Log = CreateConVar("sm_manager_log", "0", "Log a bunch of checks.", FCVAR_NONE, true, 0.0, true, 1.0);

	RegConsoleCmd("sm_steamid", Command_SteamID, "Retrieves your Steam ID");
	RegAdminCmd("sm_auth", Command_GetAuth, ADMFLAG_GENERIC, "Retrieves the Steam ID of a player");

	AutoExecConfig(true);
}

public void OnClientPutInServer(int client)
{
	char sSteamID[64];
	GetClientAuthId(client, AuthId_Steam2, sSteamID, sizeof(sSteamID), false);
	FormatEx(sAuthID32[client], sizeof(sAuthID32[]), "%s", sSteamID);

	char sSteamIDVerified[64];
	GetClientAuthId(client, AuthId_Steam2, sSteamIDVerified, sizeof(sSteamIDVerified));
	FormatEx(sAuthID32Verified[client], sizeof(sAuthID32Verified[]), "%s", sSteamIDVerified);
}

public void OnClientDisconnect(int client)
{
	FormatEx(sAuthID32[client], sizeof(sAuthID32[]), "");
	FormatEx(sAuthID32Verified[client], sizeof(sAuthID32Verified[]), "");
}

#if defined _Connect_Included
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

public void OnClientAuthorized(int client, const char[] sAuthID)
{
	bool bAuthTicket = GetFeatureStatus(FeatureType_Native, "SteamClientGotValidateAuthTicketResponse") == FeatureStatus_Available;
	bool bAuthenticated = GetFeatureStatus(FeatureType_Native, "SteamClientAuthenticated") == FeatureStatus_Available;

	if (!g_hCvar_BlockSpoof.BoolValue
	|| !bAuthTicket || !bAuthenticated
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

	SQLSelect_Connection(INVALID_HANDLE, pack);
}

public Action OnClientPreAdminCheck(int client)
{
	bool bAuthTicket = GetFeatureStatus(FeatureType_Native, "SteamClientGotValidateAuthTicketResponse") == FeatureStatus_Available;
	bool bAuthenticated = GetFeatureStatus(FeatureType_Native, "SteamClientAuthenticated") == FeatureStatus_Available;

	if(!g_hCvar_BlockAdmin.BoolValue || !bAuthTicket || !bAuthenticated || IsFakeClient(client) || IsClientSourceTV(client))
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
	bool bAuthTicket = GetFeatureStatus(FeatureType_Native, "SteamClientGotValidateAuthTicketResponse") == FeatureStatus_Available;
	bool bAuthenticated = GetFeatureStatus(FeatureType_Native, "SteamClientAuthenticated") == FeatureStatus_Available;

	if (!g_hCvar_BlockVoice.BoolValue || !bAuthTicket || !bAuthenticated || IsFakeClient(client) || IsClientSourceTV(client))
		return;

	if(SteamClientGotValidateAuthTicketResponse(sAuthID32[client]) && !SteamClientAuthenticated(sAuthID32[client]))
	{
		LogMessage("%L was not authenticated with steam, muting client.", client);
		BaseComm_SetClientMute(client, true);
		return;
	}
}

public void OnValidateAuthTicketResponse(EAuthSessionResponse eAuthSessionResponse, bool bGotValidateAuthTicketResponse, bool bSteamLegal, char sSteam32ID[32])
{
	if (g_hCvar_Log.BoolValue)
		LogMessage("OnValidateAuthTicketResponse: Response(%d), GotValidate(%d), Legal(%d), SteamID(%s)", eAuthSessionResponse, bGotValidateAuthTicketResponse, bSteamLegal, sSteam32ID);

	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientConnected(i))
		{
			if (StrEqual(sAuthID32[i], sSteam32ID, false))
			{
				LogPotentialSpoofer(i);
				break;
			}
		}
	}
}
#endif

#if defined _ProxyKiller_included_
public Action ProxyKiller_DoCheckClient(int client)
{
	if (g_hCvar_BlockVPN.IntValue <= view_as<int>(vpn_Disable))
		return Plugin_Handled;

	if (g_hCvar_BlockVPN.IntValue == view_as<int>(vpn_Everyone))
		return Plugin_Continue;

#if defined _Connect_Included
	bool bAuthTicket = GetFeatureStatus(FeatureType_Native, "SteamClientGotValidateAuthTicketResponse") == FeatureStatus_Available;
	bool bAuthenticated = GetFeatureStatus(FeatureType_Native, "SteamClientAuthenticated") == FeatureStatus_Available;

	if (!bAuthTicket || !bAuthenticated)
		return Plugin_Continue;

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

public Action Command_GetAuth(int client, int args)
{
	if(args < 1)
	{
		CReplyToCommand(client, "{green}[SM] {default}Usage: sm_auth <#userid|name>");
		return Plugin_Handled;
	}

	char sTarget[MAX_TARGET_LENGTH];
	GetCmdArg(1, sTarget, sizeof(sTarget));

	int iTarget;
	if ((iTarget = FindTarget(client, sTarget, false, false)) <= 0)
		return Plugin_Handled;

	CReplyToCommand(client, "{green}[SM] {default}Steam ID for player {olive}%N {default}is: {blue}%s", iTarget, sAuthID32Verified[iTarget]);

	return Plugin_Handled;
}

public Action Command_SteamID(int client, int args)
{
	if (client < 1 || client > MaxClients)
	{
		ReplyToCommand(client, "[SM] Can't run this command from server console");
		return Plugin_Handled;
	}

	CReplyToCommand(client, "{green}[SM] {olive}%N{default}, your Steam ID is: {blue}%s", client, sAuthID32Verified[client]);

	return Plugin_Handled;
}

#if defined _Connect_Included
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

	SQLSetNames(INVALID_HANDLE);

	SQLTableCreation_Connection(INVALID_HANDLE);

	SQL_UnlockDatabase(g_hDatabase);
}

stock Action SQLSetNames(Handle timer)
{
	if (!g_bSQLite)
		SQL_TQuery(g_hDatabase, OnSqlSetNames, "SET NAMES \"UTF8\"");
	return Plugin_Stop;
}

stock void OnSqlSetNames(Handle hParent, Handle hChild, const char[] err, any data)
{
	if (hChild == null)
	{
		LogError("Database error while setting names as utf8. (%s)", err);
		return;
	}
}

stock Action SQLTableCreation_Connection(Handle timer)
{
	if (g_bSQLite)
		SQL_TQuery(g_hDatabase, OnSQLTableCreated_Connection, "CREATE TABLE IF NOT EXISTS connection (`auth` TEXT NOT NULL, `type` INTEGER(2) NOT NULL, `address` VARCHAR(16) NOT NULL, `timestamp` INTEGER(32) NOT NULL, PRIMARY KEY (`auth`));");
	else
		SQL_TQuery(g_hDatabase, OnSQLTableCreated_Connection, "CREATE TABLE IF NOT EXISTS connection (`auth` VARCHAR(32) NOT NULL, `type` INT(2) NOT NULL, `address` VARCHAR(16) NOT NULL, `timestamp` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY (`auth`));");
	return Plugin_Stop;
}

public void OnSQLTableCreated_Connection(Handle hParent, Handle hChild, const char[] err, any data)
{
	if (hChild == null)
	{
		LogError("Database error while creating/checking for \"connection\" table. (%s)", DATABASE_NAME, err);
		return;
	}
}

stock Action SQLSelect_Connection(Handle timer, any data)
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

stock Action SQLInsert_Connection(Handle timer, any data)
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

	SQLInsert_Connection(INVALID_HANDLE, data);
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

	bool bAuthenticated = GetFeatureStatus(FeatureType_Native, "SteamClientAuthenticated") == FeatureStatus_Available;
	if (bAuthenticated && IsClientConnected(client) && !SteamClientAuthenticated(sAuthID32Verified[client]))
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

	bool bAuthenticated = GetFeatureStatus(FeatureType_Native, "SteamClientAuthenticated") == FeatureStatus_Available;
	if (!bAuthenticated || (bAuthenticated && SteamClientAuthenticated(sAuthID32[client])))
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

#if defined _Connect_Included
	bool bAuthenticated = GetFeatureStatus(FeatureType_Native, "SteamClientAuthenticated") == FeatureStatus_Available;
	if (!bAuthenticated || (bAuthenticated && SteamClientAuthenticated(sAuthID32[client])))
		return 1;

	return 0;
#else
	return 1;
#endif
}

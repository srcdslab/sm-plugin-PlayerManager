#include <SteamWorks>
#include <ProxyKiller>
#include <sourcemod>
#include <basecomm>
#include <utilshelper>
#tryinclude <connect>

#pragma semicolon 1
#pragma newdecls required

#define DATABASE_NAME					"player_manager"

/* CONVARS */
ConVar g_hCvar_BlockVPN;

#if defined _Connect_Included
ConVar g_hCvar_BlockSpoof;
ConVar g_hCvar_BlockAdmin;
ConVar g_hCvar_BlockVoice;
ConVar g_hCvar_Log;

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
	author       = "zaCade, Neon, maxime1907",
	description  = "Manage clients, block spoofers...",
	version      = "2.2"
};

public APLRes AskPluginLoad2(Handle hMyself, bool bLate, char[] sError, int errorSize)
{
#if defined _Connect_Included
	CreateNative("PM_IsPlayerSteam", Native_IsPlayerSteam);
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
#endif

	g_hCvar_Log = CreateConVar("sm_manager_log", "0", "Log a bunch of checks.", FCVAR_NONE, true, 0.0, true, 1.0);
	g_hCvar_BlockVPN = CreateConVar("sm_manager_block_vpn", "0", "1 = block everyone, 0 = disable.", FCVAR_NONE, true, 0.0, true, 1.0);

	RegConsoleCmd("sm_steamid", Command_SteamID, "Retrieves your Steam ID");
	RegAdminCmd("sm_auth", Command_GetAuth, ADMFLAG_GENERIC, "Retrieves the Steam ID of a player");

	AutoExecConfig(true);
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

	SQLSelect_Connection(INVALID_HANDLE, pack);
}

public Action OnClientPreAdminCheck(int client)
{
	if(!g_hCvar_BlockAdmin.BoolValue
	|| IsFakeClient(client) || IsClientSourceTV(client))
		return Plugin_Continue;

	char sAuthID[32];
	GetClientAuthId(client, AuthId_Steam2, sAuthID, sizeof(sAuthID), false);

	if (SteamClientGotValidateAuthTicketResponse(sAuthID) && !SteamClientAuthenticated(sAuthID))
	{
		LogMessage("%L was not authenticated with steam, denying admin.", client);
		NotifyPostAdminCheck(client);
		return Plugin_Handled;
	}

	return Plugin_Continue;
}

public void OnClientPostAdminCheck(int client)
{
	if (!g_hCvar_BlockVoice.BoolValue
	|| IsFakeClient(client) || IsClientSourceTV(client))
		return;

	char sAuthID[32];
	GetClientAuthId(client, AuthId_Steam2, sAuthID, sizeof(sAuthID), false);

	if(SteamClientGotValidateAuthTicketResponse(sAuthID) && !SteamClientAuthenticated(sAuthID))
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
			char sAuthID[32];
			GetClientAuthId(i, AuthId_Steam2, sAuthID, sizeof(sAuthID), false);
			if (StrEqual(sAuthID, sSteam32ID, false))
			{
				LogPotentialSpoofer(i);
				break;
			}
		}
	}
}
#endif

public Action ProxyKiller_DoCheckClient(int client)
{
	if (g_hCvar_BlockVPN.IntValue <= view_as<int>(vpn_Disable))
		return Plugin_Handled;

	if (g_hCvar_BlockVPN.IntValue == view_as<int>(vpn_Everyone))
		return Plugin_Continue;

#if defined _Connect_Included
	char sAuthID[32];
	GetClientAuthId(client, AuthId_Steam2, sAuthID, sizeof(sAuthID), false);

	if (SteamClientGotValidateAuthTicketResponse(sAuthID))
	{
		if (SteamClientAuthenticated(sAuthID))
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
		ReplyToCommand(client, "[SM] Usage: sm_auth <#userid|name>");
		return Plugin_Handled;
	}

	char sTarget[MAX_TARGET_LENGTH];
	GetCmdArg(1, sTarget, sizeof(sTarget));

	int iTarget;
	if ((iTarget = FindTarget(client, sTarget, false, false)) <= 0)
		return Plugin_Handled;

	char sAuthID[32];
	GetClientAuthId(iTarget, AuthId_Steam2, sAuthID, sizeof(sAuthID));

	ReplyToCommand(client, "[SM] Steam ID for player %N is:\x07CBC7FF %s", iTarget, sAuthID);

	return Plugin_Handled;
}

public Action Command_SteamID(int client, int args)
{      
	char sAuthID[64];
	GetClientAuthId(client, AuthId_Steam2, sAuthID, sizeof(sAuthID));

	ReplyToCommand(client, "[SM] %N, your Steam ID is:\x07CBC7FF %s", client, sAuthID);

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

	char sAuthID[32];
	GetClientAuthId(client, AuthId_Steam2, sAuthID, sizeof(sAuthID), false);

	char sSteam64ID[32];
	Steam32IDtoSteam64ID(sAuthID, sSteam64ID, sizeof(sSteam64ID));

	char sSteamAPIKey[64];
	GetSteamAPIKey(sSteamAPIKey, sizeof(sSteamAPIKey));

	static char sRequest[256];
	FormatEx(sRequest, sizeof(sRequest), "http://api.steampowered.com/ISteamUser/GetPlayerSummaries/v0002/?key=%s&steamids=%s&format=vdf", sSteamAPIKey, sSteam64ID);

	Handle hRequest = SteamWorks_CreateHTTPRequest(k_EHTTPMethodGET, sRequest);
	if (!hRequest ||
		!SteamWorks_SetHTTPRequestContextValue(hRequest, client) ||
		!SteamWorks_SetHTTPCallbacks(hRequest, OnTransferComplete) ||
		!SteamWorks_SendHTTPRequest(hRequest))
	{
		CloseHandle(hRequest);
	}
}

public int OnTransferComplete(Handle hRequest, bool bFailure, bool bRequestSuccessful, EHTTPStatusCode eStatusCode, int client)
{
	if (bFailure || !bRequestSuccessful || eStatusCode != k_EHTTPStatusCode200OK)
	{
		// Private profile or maybe steam down?
		CloseHandle(hRequest);
		return;
	}

	int Length;
	SteamWorks_GetHTTPResponseBodySize(hRequest, Length);

	char[] sData = new char[Length];
	SteamWorks_GetHTTPResponseBodyData(hRequest, sData, Length);

	CloseHandle(hRequest);

	APIWebResponse(sData, client);
}

public void APIWebResponse(const char[] sData, int client)
{
	KeyValues Response = new KeyValues("SteamAPIResponse");
	if(!Response.ImportFromString(sData, "SteamAPIResponse"))
	{
		LogError("ImportFromString(sData, \"SteamAPIResponse\") failed.");
		delete Response;
		return;
	}

	if(!Response.JumpToKey("players"))
	{
		LogError("JumpToKey(\"players\") failed.");
		delete Response;
		return;
	}

	if(!Response.GotoFirstSubKey())
	{
		delete Response;
		return;
	}

	if (IsClientConnected(client))
	{
		char sSteamID[32];

		GetClientAuthId(client, AuthId_Steam2, sSteamID, sizeof(sSteamID));

		if (!SteamClientAuthenticated(sSteamID))
		{
			LogMessage("Potential spoofer %N %s", client, sSteamID);
		}
	}

	delete Response;
}

//  888b    888        d8888 88888888888 8888888 888     888 8888888888 .d8888b.
//  8888b   888       d88888     888       888   888     888 888       d88P  Y88b
//  88888b  888      d88P888     888       888   888     888 888       Y88b.
//  888Y88b 888     d88P 888     888       888   Y88b   d88P 8888888    "Y888b.
//  888 Y88b888    d88P  888     888       888    Y88b d88P  888           "Y88b.
//  888  Y88888   d88P   888     888       888     Y88o88P   888             "888
//  888   Y8888  d8888888888     888       888      Y888P    888       Y88b  d88P
//  888    Y888 d88P     888     888     8888888     Y8P     8888888888 "Y8888P"

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

	char sAuthID[32];
	GetClientAuthId(client, AuthId_Steam2, sAuthID, sizeof(sAuthID), false);

	if (SteamClientAuthenticated(sAuthID))
		return 1;

	return 0;
}

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

	char sAuthID[32];
	GetClientAuthId(client, AuthId_Steam2, sAuthID, sizeof(sAuthID), false);

	if(SteamClientAuthenticated(sAuthID))
		SetNativeCellRef(2, 1);

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

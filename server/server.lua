-- =============================================
--   SH-TAXIJOB | Server  (v3)
-- =============================================
local QBCore, QBX
local Framework = 'none'

-- Helper de debug: solo printea si Config.Debug == true
local function DBG(msg)
    if Config.Debug then print(msg) end
end


local function DetectFramework()
    if Config.Framework ~= 'auto' then Framework=Config.Framework
    elseif GetResourceState('qbx_core')=='started' then Framework='qbox'
    elseif GetResourceState('qb-core') =='started' then Framework='qbcore' end
    if     Framework=='qbox'   then QBX   =exports['qbx_core'];    DBG('^2[sh-taxijob]^0 QBX')
    elseif Framework=='qbcore' then QBCore=exports['qb-core']:GetCoreObject(); DBG('^2[sh-taxijob]^0 QBCore')
    else print('^1[sh-taxijob]^0 ERROR: sin framework.') end
end
DetectFramework()

local ActiveInventory=(function()
    if Config.Inventory~='auto' then return Config.Inventory end
    if GetResourceState('ox_inventory')=='started' then return 'ox_inventory' end
    return 'qb-inventory'
end)()

-- Registrar el stash de ox_inventory una sola vez al arrancar el recurso.
-- RegisterStash es necesario antes de cualquier forceOpenInventory;
-- sin esto ox_inventory no conoce el stash y no lo puede abrir.
if ActiveInventory == 'ox_inventory' then
    AddEventHandler('onResourceStart', function(resourceName)
        if resourceName ~= GetCurrentResourceName() then return end
        exports.ox_inventory:RegisterStash(
            Config.StashName,
            Config.StashLabel  or 'Almacén Taxi',
            Config.StashSlots  or 50,
            Config.StashWeight or 100000,
            false,   -- owner: false = stash compartido del job
            nil,     -- groups: nil = sin restricción por grupo (los permisos los maneja el script)
            nil      -- coords: nil = sin restricción de proximidad
        )
        DBG('^2[sh-taxijob]^0 Stash ox_inventory registrado: ' .. Config.StashName)
    end)
    -- También registrar si el recurso ya estaba corriendo cuando se recargó
    exports.ox_inventory:RegisterStash(
        Config.StashName,
        Config.StashLabel  or 'Almacén Taxi',
        Config.StashSlots  or 50,
        Config.StashWeight or 100000,
        false, nil, nil
    )
end

-- ─── HELPERS FRAMEWORK ───────────────────────
local function GetPlayer(src)
    if Framework=='qbox' then return QBX:GetPlayer(src)
    elseif Framework=='qbcore' then return QBCore.Functions.GetPlayer(src) end
    return nil
end
local function GetCitizenId(src)
    local p=GetPlayer(src); if not p then return nil end; return p.PlayerData.citizenid
end
local function GetPlayerName(src)
    local p=GetPlayer(src); if not p then return 'Desconocido' end
    local ci=p.PlayerData.charinfo
    return ((ci and ci.firstname) or '')..' '..((ci and ci.lastname) or '')
end
local function IsAdmin(src) return IsPlayerAceAllowed(src,'sh.taxijob.admin') end

-- ─── PERMISOS ────────────────────────────────
local owners      = {}     -- cid → true
local members     = {}     -- cid → grade
local memberNames = {}     -- cid → nombre real (para mostrar offline)
local permsLoaded = false  -- true cuando LoadPermissions terminó de leer la DB
local permsQueue  = {}     -- sources que esperan a que carguen los permisos

local function IsOwner(src)
    local c=GetCitizenId(src); return c~=nil and owners[c]==true
end
local function HasAccess(src)
    local c=GetCitizenId(src); if not c then return false end
    return owners[c]==true or members[c]~=nil
end
local function GetMemberGrade(src)
    local c=GetCitizenId(src); if not c then return 0 end
    if owners[c] then return Config.DefaultGrade end
    return members[c] or 0
end

-- ─── DUTY / SALARIO (declaradas aquí para estar disponibles en toda la función) ──
local onDuty    = {}   -- cid → bool
local nextPay   = {}   -- cid → timestamp ms
local dutyStart = {}   -- cid → timestamp segundos
local salaryMs  = 60000  -- se sobreescribe al cargar config DB

local alertasCfg = {
    TripNotify = { position='top-right',  duration=20000 },
    ClientUI   = { position='bottom-right' },
    NpcTripUI  = { position='bottom-left' },
}

-- ─── RADIO: declaraciones adelantadas (usadas antes de su definición completa) ──
local radioChannels = {}
local defaultFreqs  = {3600, 3601, 3602, 3603, 3604}
for i=1,5 do radioChannels[i]={ freq=defaultFreqs[i], members={} } end

local function GetOnDutyList()
    local list = {}
    for _,pid in ipairs(GetPlayers()) do
        pid=tonumber(pid)
        local pcid=GetCitizenId(pid)
        if pcid and HasAccess(pid) and onDuty[pcid] then
            local isO=owners[pcid]==true
            local grade=isO and Config.DefaultGrade or (members[pcid] or 0)
            table.insert(list,{src=pid,name=GetPlayerName(pid),grade=grade,isOwner=isO})
        end
    end
    return list
end

local function GetRadioState()
    local out={}
    for i=1,5 do
        local ch=radioChannels[i]; local mOut={}
        for cid,m in pairs(ch.members) do table.insert(mOut,{cid=cid,name=m.name}) end
        table.insert(out,{slot=i,freq=ch.freq,members=mOut})
    end
    return out
end

local function BroadcastRadio()
    local state=GetRadioState()
    for _,pid in ipairs(GetPlayers()) do
        pid=tonumber(pid)
        if HasAccess(pid) then TriggerClientEvent('sh-taxijob:client:radioState',pid,state) end
    end
end

-- ─── PANEL PERMS — JSON FILE (sin SQL) ──────────
-- Se guarda en  resources/sh-taxijob/data/panel_perms.json
-- Formato: { "0": { "invitar": true, "salarios": false, ... }, "1": { ... } }
local panelPerms = {}
local PERMS_FILE = 'data/panel_perms.json'

-- Serialización JSON mínima para tablas Lua (solo bool/string/number, sin ciclos)
local function LuaToJson(val, indent)
    indent = indent or 0
    local t = type(val)
    if t == 'boolean' then return val and 'true' or 'false'
    elseif t == 'number' then return tostring(val)
    elseif t == 'string' then return '"' .. val:gsub('\\','\\\\'):gsub('"','\\"') .. '"'
    elseif t == 'table' then
        -- Detectar array (claves 1..n consecutivas)
        local isArr = true; local n = 0
        for k,_ in pairs(val) do
            n = n + 1
            if type(k) ~= 'number' or k ~= math.floor(k) or k < 1 then isArr = false; break end
        end
        if isArr and n > 0 then
            local parts = {}
            for i = 1, n do parts[i] = LuaToJson(val[i], indent+2) end
            return '[' .. table.concat(parts,',') .. ']'
        else
            local parts = {}
            for k,v in pairs(val) do
                table.insert(parts, '"'..tostring(k)..'":'..LuaToJson(v, indent+2))
            end
            return '{' .. table.concat(parts,',') .. '}'
        end
    end
    return 'null'
end

-- Parser JSON mínimo (solo necesita bool, string, number, object)
local function JsonToLua(str)
    str = str:match('^%s*(.-)%s*$')  -- trim
    -- object
    if str:sub(1,1) == '{' then
        local obj = {}
        str = str:sub(2, -2)
        for key, val in str:gmatch('"([^"]+)"%s*:%s*([^,}]+)') do
            val = val:match('^%s*(.-)%s*$')
            if val == 'true' then obj[key] = true
            elseif val == 'false' then obj[key] = false
            elseif tonumber(val) then obj[key] = tonumber(val)
            elseif val:sub(1,1)=='"' then obj[key] = val:sub(2,-2)
            elseif val:sub(1,1)=='{' then obj[key] = JsonToLua(val)
            end
        end
        return obj
    end
    if str == 'true' then return true end
    if str == 'false' then return false end
    if tonumber(str) then return tonumber(str) end
    return str
end

-- Cargar perms desde JSON; si no existe o está corrupto, usa defaults de Config
-- Guardar panelPerms al archivo JSON usando json.encode
local function SavePanelPerms()
    local toSave = {}
    for grade, panels in pairs(panelPerms) do
        toSave[tostring(grade)] = panels
    end
    local encoded = json.encode(toSave)
    local ok = SaveResourceFile(GetCurrentResourceName(), PERMS_FILE, encoded, -1)
    if ok then
        DBG('^2[sh-taxijob]^0 panel_perms.json guardado (' .. tostring(#encoded) .. ' bytes).')
    else
        print('^1[sh-taxijob]^0 ERROR: SaveResourceFile falló para ' .. PERMS_FILE)
    end
end

local function LoadPanelPerms()
    panelPerms = {}
    for g, v in pairs(Config.DefaultPermissions) do
        panelPerms[g] = {}
        for panel, val in pairs(v) do panelPerms[g][panel] = val end
    end
    local fileContent = LoadResourceFile(GetCurrentResourceName(), PERMS_FILE)
    if fileContent and fileContent ~= '' then
        local ok, decoded = pcall(json.decode, fileContent)
        if ok and type(decoded) == 'table' then
            for gradeStr, panels in pairs(decoded) do
                local grade = tonumber(gradeStr)
                if grade ~= nil and type(panels) == 'table' then
                    if not panelPerms[grade] then panelPerms[grade] = {} end
                    for panel, val in pairs(panels) do
                        panelPerms[grade][panel] = (val == true)
                    end
                end
            end
            DBG('^2[sh-taxijob]^0 panel_perms.json cargado OK (' .. tostring(#fileContent) .. ' bytes).')
        else
            print('^1[sh-taxijob]^0 ERROR al parsear panel_perms.json: ' .. tostring(decoded))
        end
    else
        DBG('^3[sh-taxijob]^0 panel_perms.json no encontrado, creando con defaults.')
        SavePanelPerms()
    end
end

local function CanEdit(src, panel)
    if IsOwner(src) then return true end
    local grade=GetMemberGrade(src)
    if not panelPerms[grade] then return false end
    return panelPerms[grade][panel]==true
end

local function LoadPermissions()
    permsLoaded=false
    permsQueue=permsQueue or {}
    -- Cargar propietarios desde tabla dedicada
    MySQL.query('SELECT `citizenid`,`player_name` FROM `sh_taxijob_owners`',{},function(ownerRows)
        owners={}; members={}; memberNames={}
        if ownerRows then
            for _,r in ipairs(ownerRows) do
                owners[r.citizenid]=true
                if r.player_name and r.player_name~='' then memberNames[r.citizenid]=r.player_name end
            end
        end
        -- También mantener retrocompatibilidad con is_owner en members
        MySQL.query('SELECT `citizenid`,`is_owner`,`grade`,`player_name` FROM `sh_taxijob_members`',{},function(rows)
            if rows then
                for _,r in ipairs(rows) do
                    if r.is_owner==1 then
                        owners[r.citizenid]=true  -- retrocompatibilidad
                    elseif not owners[r.citizenid] then
                        members[r.citizenid]=r.grade or 0
                    end
                    if r.player_name and r.player_name~='' and not memberNames[r.citizenid] then
                        memberNames[r.citizenid]=r.player_name
                    end
                end
            end
            local oc,mc=0,0
            for _ in pairs(owners) do oc=oc+1 end
            for _ in pairs(members) do mc=mc+1 end
            DBG('^2[sh-taxijob]^0 Propietarios:'..oc..' Miembros:'..mc)
            permsLoaded=true
            -- Procesar los sources que estaban esperando
            for _,src in ipairs(permsQueue) do
                local cid=GetCitizenId(src)
                if cid then
                    if HasAccess(src) then
                        local name=GetPlayerName(src)
                        memberNames[cid]=name
                        MySQL.query('UPDATE `sh_taxijob_members` SET `player_name`=? WHERE `citizenid`=?',{name,cid})
                        if owners[cid] then
                            MySQL.query('UPDATE `sh_taxijob_owners` SET `player_name`=? WHERE `citizenid`=?',{name,cid})
                        end
                    end
                    TriggerClientEvent('sh-taxijob:client:receivePermission',src,{
                        hasAccess=HasAccess(src),isOwner=IsOwner(src),
                        onDuty=onDuty[cid]==true,
                        msToNext=(nextPay[cid]) and math.max(0,nextPay[cid]-os.time()*1000) or salaryMs,
                    })
                end
            end
            permsQueue={}
        end)  -- cierre query members
    end)
    LoadPanelPerms()
end

-- ─── SQL INSTALL ─────────────────────────────
local sqlReady = false   -- se pone true cuando InstallSQL termina de crear todas las tablas

local function InstallSQL()
    -- Tabla de PROPIETARIOS (separada, nunca se sobreescribe por error)
    MySQL.query([[CREATE TABLE IF NOT EXISTS `sh_taxijob_owners` (
        `citizenid`   VARCHAR(64) NOT NULL,
        `player_name` VARCHAR(128) NOT NULL DEFAULT '',
        `given_by`    VARCHAR(64) NOT NULL DEFAULT 'admin',
        `given_at`    TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY(`citizenid`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;]])

    -- Miembros (solo miembros normales, is_owner se mantiene para retrocompatibilidad)
    MySQL.query([[CREATE TABLE IF NOT EXISTS `sh_taxijob_members` (
        `citizenid` VARCHAR(64) NOT NULL,
        `is_owner`  TINYINT(1) NOT NULL DEFAULT 0,
        `grade`     INT NOT NULL DEFAULT 0,
        `given_by`  VARCHAR(64) NOT NULL DEFAULT 'admin',
        `given_at`  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY(`citizenid`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;]])
    MySQL.query("ALTER TABLE `sh_taxijob_members` ADD COLUMN IF NOT EXISTS `grade` INT NOT NULL DEFAULT 0")
    MySQL.query("ALTER TABLE `sh_taxijob_members` ADD COLUMN IF NOT EXISTS `player_name` VARCHAR(128) NOT NULL DEFAULT ''")

    -- Ubicaciones
    MySQL.query([[CREATE TABLE IF NOT EXISTS `sh_taxijob_locations` (
        `id` INT NOT NULL AUTO_INCREMENT,`loc_type` VARCHAR(32) NOT NULL UNIQUE,
        `x` FLOAT NOT NULL DEFAULT 0,`y` FLOAT NOT NULL DEFAULT 0,
        `z` FLOAT NOT NULL DEFAULT 0,`heading` FLOAT NOT NULL DEFAULT 0,
        PRIMARY KEY(`id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;]],{},function()
        for lt,loc in pairs(Config.Locations) do
            MySQL.query('SELECT COUNT(*) as c FROM `sh_taxijob_locations` WHERE `loc_type`=?',{lt},function(r)
                if r and r[1].c==0 then
                    MySQL.insert('INSERT INTO `sh_taxijob_locations`(`loc_type`,`x`,`y`,`z`,`heading`)VALUES(?,?,?,?,?)',
                        {lt,loc.coords.x,loc.coords.y,loc.coords.z,loc.heading})
                end
            end)
        end
    end)

    -- Grades
    MySQL.query([[CREATE TABLE IF NOT EXISTS `sh_taxijob_grades` (
        `grade` INT NOT NULL,`grade_name` VARCHAR(64) NOT NULL,
        `grade_label` VARCHAR(64) NOT NULL,`salary` INT NOT NULL DEFAULT 500,
        PRIMARY KEY(`grade`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;]],{},function()
        for g,d in pairs(Config.Grades) do
            MySQL.query('SELECT COUNT(*) as c FROM `sh_taxijob_grades` WHERE `grade`=?',{g},function(r)
                if r and r[1].c==0 then
                    MySQL.insert('INSERT INTO `sh_taxijob_grades`(`grade`,`grade_name`,`grade_label`,`salary`)VALUES(?,?,?,?)',
                        {g,d.name,d.label,d.salary})
                end
            end)
        end
    end)

    -- Salary config
    MySQL.query([[CREATE TABLE IF NOT EXISTS `sh_taxijob_salary_config` (
        `id` INT NOT NULL AUTO_INCREMENT,`pay_interval` INT NOT NULL DEFAULT 1,PRIMARY KEY(`id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;]],{},function()
        MySQL.query('SELECT COUNT(*) as c FROM `sh_taxijob_salary_config`',{},function(r)
            if r and r[1].c==0 then
                MySQL.insert('INSERT INTO `sh_taxijob_salary_config`(`pay_interval`)VALUES(?)',{Config.SalaryInterval})
            end
        end)
    end)

    -- Marker config
    MySQL.query([[CREATE TABLE IF NOT EXISTS `sh_taxijob_marker_config` (
        `id` INT NOT NULL AUTO_INCREMENT,`marker_type` INT NOT NULL DEFAULT 1,
        `color_name` VARCHAR(32) NOT NULL DEFAULT 'Celeste',
        `r` INT NOT NULL DEFAULT 80,`g` INT NOT NULL DEFAULT 180,
        `b` INT NOT NULL DEFAULT 255,`a` INT NOT NULL DEFAULT 160,
        `scale_xy` FLOAT NOT NULL DEFAULT 1.5,`scale_z` FLOAT NOT NULL DEFAULT 0.5,
        PRIMARY KEY(`id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;]],{},function()
        MySQL.query('SELECT COUNT(*) as c FROM `sh_taxijob_marker_config`',{},function(r)
            if r and r[1].c==0 then
                local m=Config.DefaultMarker
                MySQL.insert('INSERT INTO `sh_taxijob_marker_config`(`marker_type`,`color_name`,`r`,`g`,`b`,`a`,`scale_xy`,`scale_z`)VALUES(?,?,?,?,?,?,?,?)',
                    {m.markerType,m.colorName,m.r,m.g,m.b,m.a,m.scaleXY,m.scaleZ})
            end
        end)
    end)

    -- Service log
    MySQL.query([[CREATE TABLE IF NOT EXISTS `sh_taxijob_service_log` (
        `id` INT NOT NULL AUTO_INCREMENT,`citizenid` VARCHAR(64) NOT NULL,
        `player_name` VARCHAR(128) NOT NULL,`action` VARCHAR(16) NOT NULL,
        `log_time` BIGINT NOT NULL,`duration` INT DEFAULT NULL,
        PRIMARY KEY(`id`),INDEX(`citizenid`),INDEX(`log_time`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;]])

    -- Trip config
    MySQL.query([[CREATE TABLE IF NOT EXISTS `sh_taxijob_trip_config` (
        `id` INT NOT NULL AUTO_INCREMENT,
        `base_price`   INT NOT NULL DEFAULT 1500,
        `price_per_unit` INT NOT NULL DEFAULT 70,
        `unit_meters`  INT NOT NULL DEFAULT 40,
        `tip1` INT NOT NULL DEFAULT 500,
        `tip2` INT NOT NULL DEFAULT 1000,
        `tip3` INT NOT NULL DEFAULT 2000,
        `tip4` INT NOT NULL DEFAULT 5000,
        PRIMARY KEY(`id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;]],{},function()
        MySQL.query('SELECT COUNT(*) as c FROM `sh_taxijob_trip_config`',{},function(r)
            if r and r[1].c==0 then
                local d=Config.TripDefaults
                MySQL.insert('INSERT INTO `sh_taxijob_trip_config`(`base_price`,`price_per_unit`,`unit_meters`,`tip1`,`tip2`,`tip3`,`tip4`)VALUES(?,?,?,?,?,?,?)',
                    {d.basePrice,d.pricePerUnit,d.unitMeters,
                     Config.TipOptions[1],Config.TipOptions[2],Config.TipOptions[3],Config.TipOptions[4]})
            end
        end)
    end)

    -- Player XP
    MySQL.query([[CREATE TABLE IF NOT EXISTS `sh_taxijob_xp` (
        `citizenid` VARCHAR(64) NOT NULL,
        `xp`    INT NOT NULL DEFAULT 0,
        `level` INT NOT NULL DEFAULT 0,
        PRIMARY KEY(`citizenid`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;]])

    -- Permissions per grade/panel
    -- Tabla de permisos eliminada: los permisos se gestionan via data/panel_perms.json

    -- Purchased vehicles
    MySQL.query([[CREATE TABLE IF NOT EXISTS `sh_taxijob_vehicle_purchases` (
        `id`        INT NOT NULL AUTO_INCREMENT,
        `vehicle_model` VARCHAR(64) NOT NULL,
        `price`     INT NOT NULL DEFAULT 0,
        `purchased` TINYINT(1) NOT NULL DEFAULT 0,
        PRIMARY KEY(`id`),
        UNIQUE KEY `vehicle_model` (`vehicle_model`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;]])

    -- Trips (viajes activos e histórico)
    MySQL.query([[CREATE TABLE IF NOT EXISTS `sh_taxijob_trips` (
        `id`          INT NOT NULL AUTO_INCREMENT,
        `client_src`  INT NOT NULL,
        `client_cid`  VARCHAR(64) NOT NULL,
        `driver_src`  INT DEFAULT NULL,
        `driver_cid`  VARCHAR(64) DEFAULT NULL,
        `from_zone`   VARCHAR(128) NOT NULL DEFAULT '',
        `to_zone`     VARCHAR(128) NOT NULL DEFAULT '',
        `to_x`        FLOAT NOT NULL DEFAULT 0,
        `to_y`        FLOAT NOT NULL DEFAULT 0,
        `to_z`        FLOAT NOT NULL DEFAULT 0,
        `status`      VARCHAR(16) NOT NULL DEFAULT 'waiting',
        `total_cost`  INT NOT NULL DEFAULT 0,
        `tip`         INT NOT NULL DEFAULT 0,
        `meters`      INT NOT NULL DEFAULT 0,
        `created_at`  BIGINT NOT NULL,
        `finished_at` BIGINT DEFAULT NULL,
        PRIMARY KEY(`id`),INDEX(`status`),INDEX(`client_cid`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;]])

    -- Hotkeys del civil (configurables por propietario)
    MySQL.query([[CREATE TABLE IF NOT EXISTS `sh_taxijob_hotkeys` (
        `id`     INT NOT NULL AUTO_INCREMENT,
        `slot`   INT NOT NULL UNIQUE,  -- 1..5
        `label`  VARCHAR(64) NOT NULL DEFAULT '',
        `key`    VARCHAR(8)  NOT NULL DEFAULT '',
        PRIMARY KEY(`id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;]], {}, function()
        MySQL.query('SELECT COUNT(*) as c FROM `sh_taxijob_hotkeys`',{},function(r)
            if r and r[1].c == 0 then
                local defaults={
                    {1,'Propina opción 1','1'},
                    {2,'Propina opción 2','2'},
                    {3,'Propina opción 3','3'},
                    {4,'Propina opción 4','4'},
                    {5,'Cambiar destino','5'},
                    {6,'Aceptar viaje (taxista)','A'},
                }
                for _,d in ipairs(defaults) do
                    MySQL.insert('INSERT INTO `sh_taxijob_hotkeys`(`slot`,`label`,`key`)VALUES(?,?,?)',d)
                end
            end
        end)
    end)

    -- Sin seed SQL para permisos: se usan defaults del config via panel_perms.json

    -- Seed vehículos comprados
    MySQL.query('SELECT COUNT(*) as c FROM `sh_taxijob_vehicle_purchases`',{},function(r)
        if r and r[1].c == 0 then
            for _,veh in ipairs(Config.SpawnVehicles) do
                local price=veh.price or 0
                MySQL.insert('INSERT INTO `sh_taxijob_vehicle_purchases`(`vehicle_model`,`price`,`purchased`)VALUES(?,?,?)',
                    {veh.model,price,0})
            end
            DBG('^2[sh-taxijob]^0 Vehículos inicializados para compra.')
        end
    end)

    -- Historial de viajes realizados (últimos N para el panel)
    MySQL.query([[CREATE TABLE IF NOT EXISTS `sh_taxijob_trip_history` (
        `id`          INT NOT NULL AUTO_INCREMENT,
        `driver_cid`  VARCHAR(64) NOT NULL,
        `driver_name` VARCHAR(128) NOT NULL DEFAULT '',
        `trip_cost`   INT NOT NULL DEFAULT 0,
        `tip`         INT NOT NULL DEFAULT 0,
        `meters`      INT NOT NULL DEFAULT 0,
        `finished_at` BIGINT NOT NULL,
        PRIMARY KEY(`id`),
        INDEX(`driver_cid`),
        INDEX(`finished_at`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;]])

    -- Cuenta de sociedad / empresa
    MySQL.query([[CREATE TABLE IF NOT EXISTS `sh_taxijob_society` (
        `id`      INT NOT NULL AUTO_INCREMENT,
        `balance` BIGINT NOT NULL DEFAULT 0,
        PRIMARY KEY(`id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;]],{},function()
        MySQL.query('SELECT COUNT(*) as c FROM `sh_taxijob_society`',{},function(r)
            if r and r[1].c==0 then
                MySQL.insert('INSERT INTO `sh_taxijob_society`(`balance`)VALUES(0)')
            end
        end)
    end)

    -- Movimientos de cuenta empresa
    MySQL.query([[CREATE TABLE IF NOT EXISTS `sh_taxijob_society_log` (
        `id`          INT NOT NULL AUTO_INCREMENT,
        `type`        VARCHAR(16) NOT NULL DEFAULT 'trip',   -- trip|deposit|withdraw|bonus
        `amount`      INT NOT NULL DEFAULT 0,
        `description` VARCHAR(128) NOT NULL DEFAULT '',
        `done_by`     VARCHAR(128) NOT NULL DEFAULT '',
        `created_at`  BIGINT NOT NULL,
        PRIMARY KEY(`id`),INDEX(`created_at`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;]])

    -- Nombre de empresa (configurable por propietario)
    MySQL.query([[CREATE TABLE IF NOT EXISTS `sh_taxijob_company` (
        `id`           INT NOT NULL AUTO_INCREMENT,
        `company_name` VARCHAR(128) NOT NULL DEFAULT 'Taxi Corp',
        PRIMARY KEY(`id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;]],{},function()
        MySQL.query('SELECT COUNT(*) as c FROM `sh_taxijob_company`',{},function(r)
            if r and r[1].c==0 then
                MySQL.insert('INSERT INTO `sh_taxijob_company`(`company_name`)VALUES(?)',{'Taxi Corp'})
            end
        end)
    end)

    -- Notas de empleados (una por jugador, visible a todos del job)
    MySQL.query([[CREATE TABLE IF NOT EXISTS `sh_taxijob_notes` (
        `citizenid`   VARCHAR(64) NOT NULL,
        `player_name` VARCHAR(128) NOT NULL DEFAULT '',
        `note`        TEXT NOT NULL DEFAULT '',
        `updated_at`  BIGINT NOT NULL DEFAULT 0,
        PRIMARY KEY(`citizenid`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;]])

    Citizen.SetTimeout(2000,LoadPermissions)
    sqlReady = true
    DBG('^2[sh-taxijob]^0 SQL listo.')
end

    -- Config de alertas (posición y duración de TripNotify, ClientUI y NpcTripUI)
    MySQL.query([[CREATE TABLE IF NOT EXISTS `sh_taxijob_alertas_config` (
        `id`               INT NOT NULL AUTO_INCREMENT,
        `trip_notify_pos`  VARCHAR(32) NOT NULL DEFAULT 'top-right',
        `trip_notify_dur`  INT NOT NULL DEFAULT 20000,
        `client_ui_pos`    VARCHAR(32) NOT NULL DEFAULT 'bottom-right',
        `npc_trip_ui_pos`  VARCHAR(32) NOT NULL DEFAULT 'bottom-left',
        PRIMARY KEY(`id`)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;]],{},function()
        -- Agregar columna si la tabla ya existía sin ella (upgrade seguro)
        MySQL.query("ALTER TABLE `sh_taxijob_alertas_config` ADD COLUMN IF NOT EXISTS `npc_trip_ui_pos` VARCHAR(32) NOT NULL DEFAULT 'bottom-left'")
        MySQL.query('SELECT COUNT(*) as c FROM `sh_taxijob_alertas_config`',{},function(r)
            if r and r[1].c==0 then
                local a=Config.AlertasConfig
                MySQL.insert(
                    'INSERT INTO `sh_taxijob_alertas_config`(`trip_notify_pos`,`trip_notify_dur`,`client_ui_pos`,`npc_trip_ui_pos`)VALUES(?,?,?,?)',
                    { a.TripNotify.position, a.TripNotify.duration, a.ClientUI.position, 'bottom-left' }
                )
            end
        end)
    end)

AddEventHandler('onResourceStart',function(res)
    if res~=GetCurrentResourceName() then return end
    Citizen.SetTimeout(1500,InstallSQL)
end)

Citizen.CreateThread(function()
    Citizen.Wait(5000)
    MySQL.query('SELECT * FROM `sh_taxijob_alertas_config` LIMIT 1',{},function(r)
        if r and r[1] then
            alertasCfg.TripNotify.position = r[1].trip_notify_pos or Config.AlertasConfig.TripNotify.position
            alertasCfg.TripNotify.duration = r[1].trip_notify_dur or Config.AlertasConfig.TripNotify.duration
            alertasCfg.ClientUI.position   = r[1].client_ui_pos   or Config.AlertasConfig.ClientUI.position
            alertasCfg.NpcTripUI.position  = r[1].npc_trip_ui_pos or 'bottom-left'
        end
    end)
end)

-- ─── DUTY & SALARIO ──────────────────────────
-- onDuty/nextPay/dutyStart/salaryMs declarados arriba
salaryMs=Config.SalaryInterval*60000  -- inicializar con valor del config

Citizen.CreateThread(function()
    Citizen.Wait(5000)
    MySQL.query('SELECT `pay_interval` FROM `sh_taxijob_salary_config` LIMIT 1',{},function(r)
        if r and r[1] then salaryMs=r[1].pay_interval*60000 end
    end)
end)

Citizen.CreateThread(function()
    Citizen.Wait(8000)
    while true do
        Citizen.Wait(5000)
        local now=os.time()*1000
        for _,src in ipairs(GetPlayers()) do
            src=tonumber(src)
            local cid=GetCitizenId(src)
            if cid and onDuty[cid] and nextPay[cid] and now>=nextPay[cid] then
                local grade=GetMemberGrade(src)
                MySQL.query('SELECT `salary` FROM `sh_taxijob_grades` WHERE `grade`=?',{grade},function(res)
                    if res and res[1] then
                        local amount=res[1].salary
                        local ply=GetPlayer(src)
                        if ply then
                            ply.Functions.AddMoney('bank',amount,'salary-taxijob')
                            TriggerClientEvent('sh-taxijob:client:notify',src,{
                                type='success',title='Salario Taxi',
                                message='Recibiste $'..amount..' (Grado '..grade..').'})
                        end
                    end
                end)
                nextPay[cid]=now+salaryMs
                TriggerClientEvent('sh-taxijob:client:updateNextPay',src,salaryMs)
            end
        end
    end
end)

RegisterNetEvent('sh-taxijob:server:toggleDuty',function()
    local src=source
    if not HasAccess(src) then return end
    local cid=GetCitizenId(src); local name=GetPlayerName(src)
    if not cid then return end
    onDuty[cid]=not onDuty[cid]
    local nowSec=os.time()
    if onDuty[cid] then
        nextPay[cid]=nowSec*1000+salaryMs; dutyStart[cid]=nowSec
        TriggerClientEvent('sh-taxijob:client:updateNextPay',src,salaryMs)
        MySQL.insert('INSERT INTO `sh_taxijob_service_log`(`citizenid`,`player_name`,`action`,`log_time`)VALUES(?,?,?,?)',
            {cid,name,'start',nowSec})
        local entry={action='start',name=name,time=nowSec,duration=nil}
        for _,pid in ipairs(GetPlayers()) do
            pid=tonumber(pid)
            if HasAccess(pid) then
                TriggerClientEvent('sh-taxijob:client:serviceLogEntry',pid,entry)
                if pid~=src then TriggerClientEvent('sh-taxijob:client:refreshTablet',pid) end
            end
        end
        -- Iniciar/recuperar timer de misiones diarias al entrar a servicio
        local function GetOrCreateDailyTimerLocal(pcid, cb)
            local nowMs = os.time() * 1000
            MySQL.query('SELECT `reset_at` FROM `sh_taxijob_daily_timer` WHERE `citizenid`=?', {pcid}, function(r)
                if r and r[1] and r[1].reset_at > nowMs then
                    cb(r[1].reset_at - nowMs)
                else
                    local resetAt = nowMs + (Config.DailyMissionResetSeconds or 86400) * 1000
                    MySQL.query(
                        'INSERT INTO `sh_taxijob_daily_timer`(`citizenid`,`reset_at`) VALUES(?,?) ON DUPLICATE KEY UPDATE `reset_at`=?',
                        {pcid, resetAt, resetAt}, function() cb(resetAt - nowMs) end)
                end
            end)
        end
        GetOrCreateDailyTimerLocal(cid, function(msLeft)
            TriggerClientEvent('sh-taxijob:client:updateDailyTimer', src, msLeft)
        end)
    else
        local dur=dutyStart[cid] and (nowSec-dutyStart[cid]) or 0
        nextPay[cid]=nil; dutyStart[cid]=nil
        MySQL.insert('INSERT INTO `sh_taxijob_service_log`(`citizenid`,`player_name`,`action`,`log_time`,`duration`)VALUES(?,?,?,?,?)',
            {cid,name,'stop',nowSec,dur})
        local entry={action='stop',name=name,time=nowSec,duration=dur}
        for _,pid in ipairs(GetPlayers()) do
            pid=tonumber(pid)
            if HasAccess(pid) then
                TriggerClientEvent('sh-taxijob:client:serviceLogEntry',pid,entry)
                if pid~=src then TriggerClientEvent('sh-taxijob:client:refreshTablet',pid) end
            end
        end
    end
    TriggerClientEvent('sh-taxijob:client:dutyState',src,onDuty[cid])
    TriggerClientEvent('sh-taxijob:client:notify',src,{
        type=onDuty[cid] and 'success' or 'info',title='Servicio Taxi',
        message=onDuty[cid] and 'Iniciaste servicio.' or 'Finalizaste servicio.'})
    -- Actualizar lista de servicio en radio para todos
    Citizen.SetTimeout(100, function()
        for _,pid in ipairs(GetPlayers()) do
            pid=tonumber(pid)
            if HasAccess(pid) then
                TriggerClientEvent('sh-taxijob:client:radioOnDuty',pid,GetOnDutyList())
            end
        end
        -- Si salió de servicio, sacarlo de todos los canales de radio
        if not onDuty[cid] then
            for i=1,5 do
                if radioChannels[i] and radioChannels[i].members[cid] then
                    radioChannels[i].members[cid]=nil
                end
            end
            -- Decirle al cliente que salga de pma-voice
            TriggerClientEvent('sh-taxijob:client:setRadioFreq',src,0)
            BroadcastRadio()
        end
    end)
end)

-- ─── COMMANDS ────────────────────────────────
RegisterCommand('dartaxijob',function(source,args)
    if source~=0 and not IsAdmin(source) then
        TriggerClientEvent('sh-taxijob:client:notify',source,{type='error',title='Sin Permiso',message='Solo admins.'})
        return
    end
    local tid=tonumber(args[1])
    if not tid then
        local m='Uso: /dartaxijob [id]'
        if source~=0 then TriggerClientEvent('sh-taxijob:client:notify',source,{type='error',title='Uso',message=m})
        else DBG('[sh-taxijob] '..m) end
        return
    end
    local cid=GetCitizenId(tid)
    if not cid then
        TriggerClientEvent('sh-taxijob:client:notify',source,{type='error',title='No encontrado',message='ID '..tid..' no conectado.'})
        return
    end
    local adminName=(source~=0) and GetPlayerName(source) or 'Consola'
    owners[cid]=true
    local pname=GetPlayerName(tid)
    memberNames[cid]=pname
    -- Guardar en tabla dedicada de propietarios (nunca se sobreescribe por error)
    MySQL.query('INSERT INTO `sh_taxijob_owners`(`citizenid`,`player_name`,`given_by`) VALUES(?,?,?) ON DUPLICATE KEY UPDATE `player_name`=?,`given_by`=?',
        {cid,pname,adminName,pname,adminName})
    -- También mantener members para retrocompatibilidad
    MySQL.query('INSERT INTO `sh_taxijob_members`(`citizenid`,`is_owner`,`grade`,`player_name`,`given_by`)VALUES(?,1,?,?,?) ON DUPLICATE KEY UPDATE `is_owner`=1,`player_name`=?,`given_by`=?',
        {cid,Config.DefaultGrade,pname,adminName,pname,adminName})
    TriggerClientEvent('sh-taxijob:client:notify',tid,{type='success',title='¡Propietario Taxi!',message='Usá /taxijob.'})
    if source~=0 then
        TriggerClientEvent('sh-taxijob:client:notify',source,{type='success',title='Listo',message=GetPlayerName(tid)..' es propietario.'})
    end
    TriggerClientEvent('sh-taxijob:client:receivePermission',tid,{hasAccess=true,isOwner=true,onDuty=false,msToNext=salaryMs})
end,false)

-- ─── /sacartaxijob ───────────────────────────
RegisterCommand('sacartaxijob',function(source,args)
    if source~=0 and not IsAdmin(source) then
        TriggerClientEvent('sh-taxijob:client:notify',source,
            {type='error',title='Sin Permiso',message='Solo admins.'})
        return
    end
    local tid=tonumber(args[1])
    if not tid then
        local m='Uso: /sacartaxijob [id]'
        if source~=0 then TriggerClientEvent('sh-taxijob:client:notify',source,{type='error',title='Uso',message=m})
        else DBG('[sh-taxijob] '..m) end
        return
    end
    local cid=GetCitizenId(tid)
    if not cid then
        -- Intentar buscar por citizenid directamente si no está conectado
        TriggerClientEvent('sh-taxijob:client:notify',source,
            {type='error',title='No encontrado',message='ID '..tid..' no está conectado.'})
        return
    end
    local adminName=(source~=0) and GetPlayerName(source) or 'Consola'
    owners[cid]=nil; members[cid]=nil
    onDuty[cid]=nil; nextPay[cid]=nil; dutyStart[cid]=nil
    MySQL.query('DELETE FROM `sh_taxijob_owners` WHERE `citizenid`=?',{cid})
    MySQL.query('DELETE FROM `sh_taxijob_members` WHERE `citizenid`=?',{cid})
    TriggerClientEvent('sh-taxijob:client:notify',tid,
        {type='error',title='Removido del Taxi',message='Te quitaron el acceso al Taxi Job.'})
    TriggerClientEvent('sh-taxijob:client:receivePermission',tid,
        {hasAccess=false,isOwner=false,onDuty=false,msToNext=0})
    if source~=0 then
        TriggerClientEvent('sh-taxijob:client:notify',source,
            {type='success',title='Listo',message=GetPlayerName(tid)..' fue removido del Taxi.'})
    end
    DBG('^2[sh-taxijob]^0 '..adminName..' removió a '..GetPlayerName(tid)..' del Taxi.')
end,false)

RegisterNetEvent('sh-taxijob:server:checkPermission',function()
    local src=source
    local cid=GetCitizenId(src)

    -- Si los permisos no cargaron aún, encolar este source
    if not permsLoaded then
        table.insert(permsQueue, src)
        return
    end

    -- Si el citizenid no está disponible aún (jugador cargando), reintentar
    if not cid then
        Citizen.SetTimeout(800, function()
            if not GetPlayerName(src) then return end
            local cid2=GetCitizenId(src)
            if not cid2 then return end
            if HasAccess(src) then
                local name=GetPlayerName(src)
                memberNames[cid2]=name
                MySQL.query('UPDATE `sh_taxijob_members` SET `player_name`=? WHERE `citizenid`=?',{name,cid2})
            end
            TriggerClientEvent('sh-taxijob:client:receivePermission',src,{
                hasAccess=HasAccess(src),isOwner=IsOwner(src),
                onDuty=onDuty[cid2]==true,
                msToNext=(nextPay[cid2]) and math.max(0,nextPay[cid2]-os.time()*1000) or salaryMs,
            })
        end)
        return
    end

    if HasAccess(src) then
        local name=GetPlayerName(src)
        memberNames[cid]=name
        MySQL.query('UPDATE `sh_taxijob_members` SET `player_name`=? WHERE `citizenid`=?',{name,cid})
    end

    TriggerClientEvent('sh-taxijob:client:receivePermission',src,{
        hasAccess=HasAccess(src),isOwner=IsOwner(src),
        onDuty=cid and onDuty[cid]==true or false,
        msToNext=(cid and nextPay[cid]) and math.max(0,nextPay[cid]-os.time()*1000) or salaryMs,
    })
end)

-- ─── /calltaxi ───────────────────────────────
local activeTrips={}   -- tripId → {data}
local clientTrips={}   -- clientCid → tripId
local driverTrips={}   -- driverCid → tripId

local function GetZoneName(x,y)
    -- FiveM provee GetNameOfZone pero solo funciona en cliente
    -- Pasamos las coords desde el cliente
    return 'Zona desconocida'
end

RegisterCommand('calltaxi',function(source,args)
    local src=source
    -- Si tiene el job Y está en servicio, pedir que salga
    if HasAccess(src) then
        local cid=GetCitizenId(src)
        if cid and onDuty[cid] then
            TriggerClientEvent('sh-taxijob:client:notify',src,{
                type='warning',title='Estás en Servicio',
                message='Salí del servicio primero antes de pedir un taxi.'})
            return
        end
        -- Tiene el job pero está fuera de servicio: puede pedir taxi
    end
    local cid=GetCitizenId(src)
    if not cid then return end
    if clientTrips[cid] then
        TriggerClientEvent('sh-taxijob:client:notify',src,{type='warning',title='Taxi',message='Ya tenés un viaje en curso.'})
        return
    end
    -- Pedir waypoint y zona al cliente
    -- El bloqueo si está en servicio se hace en el cliente para poder mostrar notificación interna
    TriggerClientEvent('sh-taxijob:client:requestWaypoint',src)
end,false)

-- Cliente envía coords del waypoint
RegisterNetEvent('sh-taxijob:server:submitWaypoint',function(toX,toY,toZ,toZone,fromZone,fromX,fromY,fromZ)
    local src=source
    local cid=GetCitizenId(src)
    if not cid then return end
    if clientTrips[cid] then return end

    -- Leer config de viaje
    MySQL.query('SELECT * FROM `sh_taxijob_trip_config` LIMIT 1',{},function(cfg)
        local tripCfg=cfg and cfg[1] or {base_price=1500,price_per_unit=70,unit_meters=40,tip1=500,tip2=1000,tip3=2000,tip4=5000}
        local nowSec=os.time()
        MySQL.insert('INSERT INTO `sh_taxijob_trips`(`client_src`,`client_cid`,`from_zone`,`to_zone`,`to_x`,`to_y`,`to_z`,`status`,`created_at`)VALUES(?,?,?,?,?,?,?,?,?)',
            {src,cid,fromZone or '',toZone or '',toX,toY,toZ,'waiting',nowSec},
            function(tripId)
                local tripData={
                    id=tripId, clientSrc=src, clientCid=cid,
                    driverSrc=nil, driverCid=nil,
                    fromZone=fromZone or '',toZone=toZone or '',
                    fromX=fromX or 0,fromY=fromY or 0,fromZ=fromZ or 0,
                    toX=toX,toY=toY,toZ=toZ,
                    status='waiting',
                    basePrice=tripCfg.base_price, pricePerUnit=tripCfg.price_per_unit,
                    unitMeters=tripCfg.unit_meters,
                    tips={tripCfg.tip1,tripCfg.tip2,tripCfg.tip3,tripCfg.tip4},
                    totalCost=tripCfg.base_price, meters=0,
                    tip=0,
                    locationChanged=false,
                }
                activeTrips[tripId]=tripData
                clientTrips[cid]=tripId

                -- Notificar a todos los taxistas en servicio
                local dispatch={
                    id=tripId, fromZone=tripData.fromZone, toZone=tripData.toZone,
                    basePrice=tripData.basePrice,
                }
                for _,pid in ipairs(GetPlayers()) do
                    pid=tonumber(pid)
                    local pcid=GetCitizenId(pid)
                    if pcid and (owners[pcid] or members[pcid]~=nil) and onDuty[pcid] then
                        TriggerClientEvent('sh-taxijob:client:newTripRequest',pid,dispatch)
                    end
                end
                -- Confirmar al cliente
                TriggerClientEvent('sh-taxijob:client:tripCreated',src,{
                    id=tripId, tips=tripData.tips, basePrice=tripData.basePrice,
                })
                DBG('^2[sh-taxijob]^0 Nuevo viaje #'..tripId..' de '..cid)
            end)
    end)
end)

-- Taxista acepta viaje
RegisterNetEvent('sh-taxijob:server:acceptTrip',function(tripId)
    local src=source
    if not HasAccess(src) then return end
    local cid=GetCitizenId(src)
    if not cid then return end
    if driverTrips[cid] then
        TriggerClientEvent('sh-taxijob:client:notify',src,{type='error',title='Viaje',message='Ya tenés un viaje en curso.'})
        return
    end
    local trip=activeTrips[tripId]
    if not trip then
        TriggerClientEvent('sh-taxijob:client:notify',src,{type='error',title='Viaje',message='Viaje no encontrado.'})
        return
    end
    if trip.status~='waiting' then
        TriggerClientEvent('sh-taxijob:client:notify',src,{type='warning',title='Viaje',message='Ese viaje ya fue aceptado.'})
        return
    end
    trip.status='active'; trip.driverSrc=src; trip.driverCid=cid
    driverTrips[cid]=tripId
    MySQL.update('UPDATE `sh_taxijob_trips` SET `status`=?,`driver_src`=?,`driver_cid`=? WHERE `id`=?',
        {'active',src,cid,tripId})

    -- Etapa 1: ir a buscar al civil → usar coords donde estaba cuando llamó al taxi
    -- Si el ped está disponible usamos su pos actual, sino las guardadas
    local clientPed=GetPlayerPed(trip.clientSrc)
    local cx = trip.fromX or 0
    local cy = trip.fromY or 0
    local cz = trip.fromZ or 0
    if clientPed and clientPed ~= 0 then
        local cc = GetEntityCoords(clientPed)
        if cc and cc.x ~= 0 then cx,cy,cz = cc.x,cc.y,cc.z end
    end
    -- Notificar al taxista
    TriggerClientEvent('sh-taxijob:client:tripAccepted',src,{
        id=tripId,
        clientX=cx, clientY=cy, clientZ=cz,
        fromZone=trip.fromZone,
        toX=trip.toX, toY=trip.toY, toZ=trip.toZ,
        toZone=trip.toZone,
        basePrice=trip.basePrice, pricePerUnit=trip.pricePerUnit, unitMeters=trip.unitMeters,
        tips=trip.tips, clientSrc=trip.clientSrc,
        driverServerId=src,
    })
    -- Notificar al cliente (incluye driverServerId para crear el blip del taxi)
    TriggerClientEvent('sh-taxijob:client:taxiAccepted',trip.clientSrc,{
        driverName=GetPlayerName(src),
        driverServerId=src,
        basePrice=trip.basePrice, pricePerUnit=trip.pricePerUnit, unitMeters=trip.unitMeters,
        tips=trip.tips,
    })
    -- Informar a otros taxistas
    for _,pid in ipairs(GetPlayers()) do
        pid=tonumber(pid)
        local pcid=GetCitizenId(pid)
        if pcid and (owners[pcid] or members[pcid]~=nil) and pid~=src then
            TriggerClientEvent('sh-taxijob:client:tripTaken',pid,tripId)
        end
    end
    DBG('^2[sh-taxijob]^0 Viaje #'..tripId..' aceptado por '..GetPlayerName(src))
end)

-- Taxi llegó a buscar al civil → notificarle
RegisterNetEvent('sh-taxijob:server:taxiArrived',function(tripId)
    local src=source
    local cid=GetCitizenId(src)
    if not cid then return end
    local trip=activeTrips[tripId]
    if not trip or trip.driverCid~=cid then return end
    TriggerClientEvent('sh-taxijob:client:notify',trip.clientSrc,{
        type='success',title='¡Tu taxi llegó!',
        message='Tu taxista está esperándote. Subite al vehículo para iniciar el viaje.',
        duration=8000,
    })
end)

-- Pasajero subió al taxi → notificar al civil para mostrar UI
RegisterNetEvent('sh-taxijob:server:passengerBoarded',function(tripId)
    local src=source
    local cid=GetCitizenId(src)
    if not cid then return end
    local trip=activeTrips[tripId]
    if not trip or trip.driverCid~=cid then return end
    -- Notificar al civil: subiste al taxi, mostrar UI
    -- También enviamos la config de alertas actual para que su UI quede
    -- posicionada igual que la configurada por el taxista en la tablet.
    TriggerClientEvent('sh-taxijob:client:passengerBoarded',trip.clientSrc,{
        tripId=tripId,
        basePrice=trip.basePrice,
        tips=trip.tips,
        alertasCfg={
            tripNotifyPos = alertasCfg.TripNotify.position,
            tripNotifyDur = alertasCfg.TripNotify.duration,
            clientUiPos   = alertasCfg.ClientUI.position,
            npcTripUiPos  = alertasCfg.NpcTripUI.position,
        },
    })
end)

-- Actualizar costo en tiempo real (cliente taxista envía metros)
RegisterNetEvent('sh-taxijob:server:updateTripMeters',function(tripId,meters)
    local trip=activeTrips[tripId]
    if not trip or trip.driverCid~=GetCitizenId(source) then return end
    trip.meters=meters
    local units=math.floor(meters/trip.unitMeters)
    trip.totalCost=trip.basePrice+(units*trip.pricePerUnit)
    -- Sincronizar con cliente
    TriggerClientEvent('sh-taxijob:client:tripMeterUpdate',trip.clientSrc,{
        meters=meters, totalCost=trip.totalCost,
    })
    TriggerClientEvent('sh-taxijob:client:tripMeterUpdate',trip.driverSrc,{
        meters=meters, totalCost=trip.totalCost,
    })
end)

-- Cliente cambia waypoint (solo una vez)
RegisterNetEvent('sh-taxijob:server:changeWaypoint',function(toX,toY,toZ,toZone)
    local src=source
    local cid=GetCitizenId(src)
    if not cid then return end
    local tripId=clientTrips[cid]; if not tripId then return end
    local trip=activeTrips[tripId]; if not trip then return end
    if trip.locationChanged then
        TriggerClientEvent('sh-taxijob:client:notify',src,{type='error',title='Viaje',message='Ya cambiaste el destino una vez.'})
        return
    end
    if trip.status~='active' then return end
    trip.toX=toX; trip.toY=toY; trip.toZ=toZ; trip.toZone=toZone
    trip.locationChanged=true
    MySQL.update('UPDATE `sh_taxijob_trips` SET `to_x`=?,`to_y`=?,`to_z`=?,`to_zone`=? WHERE `id`=?',
        {toX,toY,toZ,toZone,tripId})
    -- Notificar al taxista de nuevo punto
    if trip.driverSrc then
        TriggerClientEvent('sh-taxijob:client:waypointChanged',trip.driverSrc,{
            toX=toX,toY=toY,toZ=toZ,toZone=toZone,
        })
        TriggerClientEvent('sh-taxijob:client:notify',trip.driverSrc,{
            type='warning',title='Destino cambiado',message='El pasajero cambió el destino a: '..toZone})
    end
    TriggerClientEvent('sh-taxijob:client:notify',src,{type='success',title='Destino',message='Destino actualizado (no se puede volver a cambiar).'})
end)

-- Dejar propina
RegisterNetEvent('sh-taxijob:server:leaveTip',function(amount)
    local src=source
    local cid=GetCitizenId(src)
    if not cid then return end
    local tripId=clientTrips[cid]; if not tripId then return end
    local trip=activeTrips[tripId]; if not trip then return end
    if trip.status~='active' then return end
    amount=tonumber(amount); if not amount or amount<0 then return end
    trip.tip=amount
    -- Notificar al taxista
    if trip.driverSrc then
        TriggerClientEvent('sh-taxijob:client:notify',trip.driverSrc,{
            type='success',title='¡Propina!',message='El pasajero dejó una propina de $'..amount..'.'})
        TriggerClientEvent('sh-taxijob:client:tripTipUpdate',trip.driverSrc,amount)
    end
    TriggerClientEvent('sh-taxijob:client:notify',src,{type='success',title='Propina enviada',message='Dejaste $'..amount..' de propina.'})
end)

-- Finalizar viaje (solo el taxista que lo aceptó)
RegisterNetEvent('sh-taxijob:server:finishTrip',function(tripId)
    local src=source
    local cid=GetCitizenId(src)
    if not cid then return end
    local trip=activeTrips[tripId]
    if not trip or trip.driverCid~=cid or trip.status~='active' then
        TriggerClientEvent('sh-taxijob:client:notify',src,{type='error',title='Viaje',message='No podés finalizar este viaje.'})
        return
    end

    trip.status='finished'
    local nowSec=os.time()

    -- Cobrar al civil: totalCost + propina
    local clientPly=GetPlayer(trip.clientSrc)
    if clientPly then
        clientPly.Functions.RemoveMoney('bank', trip.totalCost + trip.tip, 'taxi-trip-payment')
    end

    -- El costo del viaje va a la cuenta de sociedad del job
    -- Función robusta que intenta varios sistemas en orden
-- Sistema propio de sociedad (SQL, plug & play)
local function AddToSociety(amount)
    MySQL.query('UPDATE `sh_taxijob_society` SET `balance`=`balance`+? WHERE `id`=1',{amount})
    return true
end

    AddToSociety(trip.totalCost)
    -- Registrar en log de sociedad
    
    MySQL.insert('INSERT INTO `sh_taxijob_society_log`(`type`,`amount`,`description`,`done_by`,`created_at`)VALUES(?,?,?,?,?)',
        {'trip',trip.totalCost,'Viaje #'..tripId..' ('..trip.meters..'m)',GetPlayerName(src),os.time()})

    -- La propina va directamente al taxista
    local driverPly=GetPlayer(src)
    if driverPly and trip.tip > 0 then
        driverPly.Functions.AddMoney('bank', trip.tip, 'taxi-tip')
    end

    -- Guardar viaje en historial para el panel
    MySQL.insert('INSERT INTO `sh_taxijob_trip_history`(`driver_cid`,`driver_name`,`trip_cost`,`tip`,`meters`,`finished_at`) VALUES(?,?,?,?,?,?)',
        {cid, GetPlayerName(src), trip.totalCost, trip.tip, trip.meters, nowSec})

    -- XP al taxista
    local xpGained=math.random(Config.XpPerTrip.min,Config.XpPerTrip.max)
    GiveXP(src,cid,xpGained)

    -- Update DB
    MySQL.update('UPDATE `sh_taxijob_trips` SET `status`=?,`total_cost`=?,`tip`=?,`meters`=?,`finished_at`=? WHERE `id`=?',
        {'finished',trip.totalCost,trip.tip,trip.meters,nowSec,tripId})

    -- Limpiar
    clientTrips[trip.clientCid]=nil
    driverTrips[cid]=nil
    activeTrips[tripId]=nil

    -- Notificar al taxista: solo propina como ganancia personal
    TriggerClientEvent('sh-taxijob:client:tripFinished',src,{
        totalEarned=trip.tip, tip=trip.tip, tripCost=trip.totalCost, xpGained=xpGained,
    })
    TriggerClientEvent('sh-taxijob:client:tripFinishedClient',trip.clientSrc,{
        totalCost=trip.totalCost, tip=trip.tip,
    })
    -- Actualizar panel viajes a todos
    for _,pid in ipairs(GetPlayers()) do
        pid=tonumber(pid)
        local pcid=GetCitizenId(pid)
        if pcid and (owners[pcid] or members[pcid]~=nil) then
            TriggerClientEvent('sh-taxijob:client:tripRemoved',pid,tripId)
        end
    end
    DBG('^2[sh-taxijob]^0 Viaje #'..tripId..' finalizado. Sociedad: $'..trip.totalCost..' | Propina: $'..trip.tip)
end)

-- Cancelar viaje
RegisterNetEvent('sh-taxijob:server:cancelTrip',function(tripId)
    local src=source
    local cid=GetCitizenId(src)
    if not cid then return end
    local trip=activeTrips[tripId]; if not trip then return end
    -- Solo puede cancelar el taxista que aceptó (o si está en waiting, cualquier taxista)
    if trip.status=='active' and trip.driverCid~=cid then
        TriggerClientEvent('sh-taxijob:client:notify',src,{type='error',title='Viaje',message='No podés cancelar este viaje.'})
        return
    end
    trip.status='cancelled'
    MySQL.update('UPDATE `sh_taxijob_trips` SET `status`=? WHERE `id`=?',{'cancelled',tripId})
    local savedDriverSrc=trip.driverSrc
    local savedDriverCid=trip.driverCid
    if trip.driverCid then driverTrips[trip.driverCid]=nil end
    clientTrips[trip.clientCid]=nil
    activeTrips[tripId]=nil
    -- Notificar al cliente
    TriggerClientEvent('sh-taxijob:client:notify',trip.clientSrc,{type='error',title='Viaje cancelado',message='Tu taxi fue cancelado. Podés volver a pedir.'})
    TriggerClientEvent('sh-taxijob:client:tripCancelledDriver',trip.clientSrc)
    -- Notificar al taxista que aceptó (si existe y no es quien canceló)
    if savedDriverSrc and savedDriverSrc~=src then
        TriggerClientEvent('sh-taxijob:client:notify',savedDriverSrc,{type='info',title='Viaje cancelado',message='El viaje fue cancelado.'})
        TriggerClientEvent('sh-taxijob:client:driverTripCancelled',savedDriverSrc)
    elseif src~=0 then
        -- El mismo taxista canceló, limpiar localmente
        TriggerClientEvent('sh-taxijob:client:driverTripCancelled',src)
    end
    for _,pid in ipairs(GetPlayers()) do
        pid=tonumber(pid)
        local pcid=GetCitizenId(pid)
        if pcid and (owners[pcid] or members[pcid]~=nil) then
            TriggerClientEvent('sh-taxijob:client:tripRemoved',pid,tripId)
        end
    end
end)

-- ─── XP ──────────────────────────────────────
function GiveXP(src,cid,amount)
    MySQL.query('SELECT `xp`,`level` FROM `sh_taxijob_xp` WHERE `citizenid`=?',{cid},function(r)
        local curXp=0; local curLvl=0
        if r and r[1] then curXp=r[1].xp; curLvl=r[1].level end
        local newXp=curXp+amount
        -- Calcular nivel
        local newLvl=curLvl
        for lvl=curLvl,10 do
            local nd=Config.Levels[lvl+1]
            if nd and newXp>=nd.xpRequired then newLvl=lvl+1
            else break end
        end
        MySQL.query('INSERT INTO `sh_taxijob_xp`(`citizenid`,`xp`,`level`)VALUES(?,?,?) ON DUPLICATE KEY UPDATE `xp`=?,`level`=?',
            {cid,newXp,newLvl,newXp,newLvl})
        TriggerClientEvent('sh-taxijob:client:xpUpdate',src,{xp=newXp,level=newLvl,gained=amount})
        if newLvl>curLvl then
            local lData=Config.Levels[newLvl] or {label='Nivel '..newLvl}
            TriggerClientEvent('sh-taxijob:client:notify',src,{
                type='success',title='¡Subiste de nivel!',
                message='Ahora eres '..lData.label..' (Nivel '..newLvl..') — +'..amount..' XP'})
        end
    end)
end

-- Get XP
RegisterNetEvent('sh-taxijob:server:getMyXP',function()
    local src=source; local cid=GetCitizenId(src)
    if not cid then return end
    MySQL.query('SELECT `xp`,`level` FROM `sh_taxijob_xp` WHERE `citizenid`=?',{cid},function(r)
        local xp=0; local lvl=0
        if r and r[1] then xp=r[1].xp; lvl=r[1].level end
        TriggerClientEvent('sh-taxijob:client:xpUpdate',src,{xp=xp,level=lvl,gained=0})
    end)
end)

-- ─── GET TABLET DATA ─────────────────────────
RegisterNetEvent('sh-taxijob:server:getTabletData',function()
    local src=source
    if not HasAccess(src) then return end
    local cid=GetCitizenId(src)
    MySQL.query('SELECT `grade`,`grade_name` as gname,`grade_label` as glabel,`salary` FROM `sh_taxijob_grades` ORDER BY `grade` ASC',{},function(grades)
      MySQL.query('SELECT `loc_type`,`x`,`y`,`z`,`heading` FROM `sh_taxijob_locations`',{},function(locs)
        MySQL.query('SELECT `pay_interval` FROM `sh_taxijob_salary_config` LIMIT 1',{},function(salCfg)
          MySQL.query('SELECT `marker_type`,`color_name`,`r`,`g`,`b`,`a`,`scale_xy`,`scale_z` FROM `sh_taxijob_marker_config` LIMIT 1',{},function(mCfg)
            MySQL.query('SELECT `player_name`,`action`,`log_time`,`duration` FROM `sh_taxijob_service_log` ORDER BY `log_time` DESC LIMIT '..Config.MaxServiceLogs,{},function(logs)
              MySQL.query('SELECT * FROM `sh_taxijob_trip_config` LIMIT 1',{},function(tripCfg)
                -- Permisos desde JSON (panelPerms en memoria, cargado por LoadPanelPerms)
                local perms = nil -- no se usa SQL, se lee panelPerms directamente abajo
                  MySQL.query('SELECT `xp`,`level` FROM `sh_taxijob_xp` WHERE `citizenid`=?',{cid},function(xpRow)
                    MySQL.query('SELECT `citizenid`,`is_owner`,`grade`,`player_name` FROM `sh_taxijob_members`',{},function(allM)

                        local locsOut={}
                        if locs then for _,r in ipairs(locs) do locsOut[r.loc_type]={x=r.x,y=r.y,z=r.z,heading=r.heading} end end

                        local gradesOut={}
                        if grades then for _,g in ipairs(grades) do
                            table.insert(gradesOut,{grade=g.grade,name=g.gname,label=g.glabel,salary=g.salary})
                        end end

                        local onlineCids={}
                        local employees,onDutyList={},{}
                        for _,pid in ipairs(GetPlayers()) do
                            pid=tonumber(pid)
                            local pcid=GetCitizenId(pid)
                            if pcid and (owners[pcid] or members[pcid]~=nil) then
                                local isO=owners[pcid]==true
                                local grade=isO and Config.DefaultGrade or (members[pcid] or 0)
                                local gradeLabel='Conductor'
                                for _,g in ipairs(gradesOut) do if g.grade==grade then gradeLabel=g.label break end end
                                local emp={id=pid,name=GetPlayerName(pid),grade=grade,
                                    gradeLabel=isO and 'Propietario' or gradeLabel,
                                    isOwner=isO,onDuty=onDuty[pcid]==true,online=true}
                                table.insert(employees,emp)
                                onlineCids[pcid]=true
                                if onDuty[pcid] then table.insert(onDutyList,emp) end
                            end
                        end
                        if allM then
                            for _,m in ipairs(allM) do
                                if not onlineCids[m.citizenid] then
                                    local isO=m.is_owner==1
                                    local grade=isO and Config.DefaultGrade or (m.grade or 0)
                                    local gradeLabel='Conductor'
                                    for _,g in ipairs(gradesOut) do if g.grade==grade then gradeLabel=g.label break end end
                                    -- Usar nombre guardado en la tabla o el cache
                                    local realName = (m.player_name and m.player_name~='') and m.player_name
                                                  or memberNames[m.citizenid]
                                                  or 'Empleado Offline'
                                    table.insert(employees,{id=nil,cid=m.citizenid,
                                        name=realName,
                                        grade=grade,gradeLabel=isO and 'Propietario' or gradeLabel,
                                        isOwner=isO,onDuty=false,online=false})
                                end
                            end
                        end

                        -- Perms directamente desde panelPerms (cargado del JSON, siempre actualizado)
                        local permsOut={}
                        for g,panels in pairs(panelPerms) do
                            permsOut[g]={}
                            for panel,val in pairs(panels) do
                                permsOut[g][panel]=val
                            end
                        end

                        local mc=mCfg and mCfg[1] or Config.DefaultMarker
                        local tc=tripCfg and tripCfg[1] or {base_price=1500,price_per_unit=70,unit_meters=40,tip1=500,tip2=1000,tip3=2000,tip4=5000}
                        local msLeft=(cid and nextPay[cid]) and math.max(0,nextPay[cid]-os.time()*1000) or salaryMs
                        local myXp=xpRow and xpRow[1] and {xp=xpRow[1].xp,level=xpRow[1].level} or {xp=0,level=0}

                        -- Viajes activos
                        local tripsOut={}
                        for id,t in pairs(activeTrips) do
                            table.insert(tripsOut,{
                                id=id,fromZone=t.fromZone,toZone=t.toZone,
                                status=t.status,basePrice=t.basePrice,
                                driverName=t.driverSrc and GetPlayerName(t.driverSrc) or nil,
                            })
                        end

                        -- Consultar hotkeys antes de mandar el payload
                        MySQL.query('SELECT `slot`,`label`,`key` FROM `sh_taxijob_hotkeys` ORDER BY `slot` ASC',{},function(hkRows)
                            MySQL.query('SELECT `vehicle_model`,`purchased` FROM `sh_taxijob_vehicle_purchases`',{},function(vehPurchR)
                                local vehPurch={}
                                if vehPurchR then
                                    for _,v in ipairs(vehPurchR) do
                                        -- Convertir a boolean correctamente
                                        local isPurchased = v.purchased == 1 or v.purchased == true or tostring(v.purchased):lower() == 'true'
                                        vehPurch[v.vehicle_model] = isPurchased
                                    end
                                end
                                MySQL.query('SELECT `company_name` FROM `sh_taxijob_company` WHERE `id`=1',{},function(compR)
                                local companyName=(compR and compR[1] and compR[1].company_name) or 'Taxi Corp'
                                TriggerClientEvent('sh-taxijob:client:receiveTabletData',src,{
                                    grades=gradesOut,locations=locsOut,employees=employees,
                                    onDutyList=onDutyList,isOwner=IsOwner(src),
                                    onDuty=cid and onDuty[cid]==true or false,
                                    interval=salCfg and salCfg[1] and salCfg[1].pay_interval or Config.SalaryInterval,
                                    msToNext=msLeft,
                                    markerCfg={markerType=mc.marker_type or mc.markerType,colorName=mc.color_name or mc.colorName,
                                        r=mc.r,g=mc.g,b=mc.b,a=mc.a,scaleXY=mc.scale_xy or mc.scaleXY,scaleZ=mc.scale_z or mc.scaleZ},
                                    vehicles=Config.SpawnVehicles,
                                    vehiclePurchases=vehPurch,
                                    serviceLogs=logs or {},
                                    tripConfig={basePrice=tc.base_price,pricePerUnit=tc.price_per_unit,
                                        unitMeters=tc.unit_meters,tips={tc.tip1,tc.tip2,tc.tip3,tc.tip4}},
                                    permissions=permsOut,
                                    myXp=myXp,
                                    levels=Config.Levels,
                                    activeTrips=tripsOut,
                                    myGrade=GetMemberGrade(src),
                                    myCid=cid,
                                    mySrc=src,
                                    hotkeys=hkRows or {},
                                    companyName=companyName,
                                    alertasCfg = {
        tripNotifyPos = alertasCfg.TripNotify.position,
        tripNotifyDur = alertasCfg.TripNotify.duration,
        clientUiPos   = alertasCfg.ClientUI.position,
        npcTripUiPos  = alertasCfg.NpcTripUI.position,},
                                    canEdit={
                                        ubicaciones      =CanEdit(src,'ubicaciones'),
                                        vehiculos        =CanEdit(src,'vehiculos'),
                                        salarios         =CanEdit(src,'salarios'),
                                        viajes_config    =CanEdit(src,'viajes_config'),
                                        invitar          =CanEdit(src,'invitar'),
                                        empresa          =CanEdit(src,'empresa')           or IsOwner(src),
                                        viajes_realizados=CanEdit(src,'viajes_realizados') or IsOwner(src),
                                        empleados        =CanEdit(src,'empleados')         or IsOwner(src),
                                        permisos         =IsOwner(src),
                                        alertas_config = CanEdit(src,'alertas_config'),
                                    },
                                })
                                end)
                            end)
                        end)
                  end)
                end)
              end)
            end)
          end)
        end)
      end)
    end)
end)

-- ─── UPDATES ─────────────────────────────────
RegisterNetEvent('sh-taxijob:server:updateSalary',function(grade,amount)
    local src=source; if not CanEdit(src,'salarios') then return end
    amount=tonumber(amount);grade=tonumber(grade)
    if not amount or not grade or amount<0 then return end
    MySQL.update('UPDATE `sh_taxijob_grades` SET `salary`=? WHERE `grade`=?',{amount,grade})
end)

RegisterNetEvent('sh-taxijob:server:updateSalaryInterval',function(mins)
    local src=source; if not CanEdit(src,'salarios') then return end
    mins=tonumber(mins); if not mins or mins<1 then return end
    salaryMs=mins*60000
    MySQL.update('UPDATE `sh_taxijob_salary_config` SET `pay_interval`=? WHERE `id`=1',{mins})
end)

RegisterNetEvent('sh-taxijob:server:updateMarkerConfig',function(cfg)
    local src=source; if not IsOwner(src) then return end
    MySQL.update('UPDATE `sh_taxijob_marker_config` SET `marker_type`=?,`color_name`=?,`r`=?,`g`=?,`b`=?,`a`=?,`scale_xy`=?,`scale_z`=? WHERE `id`=1',
        {cfg.markerType,cfg.colorName,cfg.r,cfg.g,cfg.b,cfg.a,cfg.scaleXY,cfg.scaleZ})
    for _,pid in ipairs(GetPlayers()) do
        pid=tonumber(pid)
        if HasAccess(pid) then TriggerClientEvent('sh-taxijob:client:updateMarker',pid,cfg) end
    end
end)

RegisterNetEvent('sh-taxijob:server:updateLocation',function(locType,x,y,z,heading)
    local src=source; if not CanEdit(src,'ubicaciones') then return end
    x=tonumber(x);y=tonumber(y);z=tonumber(z);heading=tonumber(heading) or 0
    if not x or not y or not z then return end
    MySQL.update('UPDATE `sh_taxijob_locations` SET `x`=?,`y`=?,`z`=?,`heading`=? WHERE `loc_type`=?',
        {x,y,z,heading,locType})
    for _,pid in ipairs(GetPlayers()) do
        pid=tonumber(pid)
        if HasAccess(pid) then TriggerClientEvent('sh-taxijob:client:updateLocations',pid) end
    end
end)

RegisterNetEvent('sh-taxijob:server:getLocations',function()
    local src=source; if not HasAccess(src) then return end
    MySQL.query('SELECT `loc_type`,`x`,`y`,`z`,`heading` FROM `sh_taxijob_locations`',{},function(rows)
        local locs={}
        if rows then for _,r in ipairs(rows) do locs[r.loc_type]={x=r.x,y=r.y,z=r.z,heading=r.heading} end end
        TriggerClientEvent('sh-taxijob:client:receiveLocations',src,locs)
    end)
end)

RegisterNetEvent('sh-taxijob:server:getMarkerConfig',function()
    local src=source; if not HasAccess(src) then return end
    MySQL.query('SELECT * FROM `sh_taxijob_marker_config` LIMIT 1',{},function(r)
        if r and r[1] then
            local mc=r[1]
            TriggerClientEvent('sh-taxijob:client:updateMarker',src,{
                markerType=mc.marker_type,colorName=mc.color_name,
                r=mc.r,g=mc.g,b=mc.b,a=mc.a,scaleXY=mc.scale_xy,scaleZ=mc.scale_z,
                drawDistance=Config.DefaultMarker.drawDistance})
        end
    end)
end)

RegisterNetEvent('sh-taxijob:server:getAlertasConfig',function()
    local src=source
    if not HasAccess(src) then return end
    TriggerClientEvent('sh-taxijob:client:receiveAlertasConfig',src,{
        tripNotifyPos = alertasCfg.TripNotify.position,
        tripNotifyDur = alertasCfg.TripNotify.duration,
        clientUiPos   = alertasCfg.ClientUI.position,
        npcTripUiPos  = alertasCfg.NpcTripUI.position,
    })
end)

RegisterNetEvent('sh-taxijob:server:updateAlertasConfig',function(data)
    local src=source
    -- Solo quien tiene permiso 'alertas_config' o es owner puede editar
    if not CanEdit(src,'alertas_config') then
        TriggerClientEvent('sh-taxijob:client:notify',src,{
            type='error',title='Sin Permiso',message='No tenés permiso para editar las alertas.'})
        return
    end

    -- Validar posiciones permitidas
    local validPos = {
        ['top-right']=true,['top-left']=true,['top-center']=true,
        ['center-right']=true,['center-left']=true,['center']=true,
        ['bottom-right']=true,['bottom-left']=true,['bottom-center']=true,
    }
    local tnPos   = (data.tripNotifyPos and validPos[data.tripNotifyPos]) and data.tripNotifyPos or alertasCfg.TripNotify.position
    local cuPos   = (data.clientUiPos   and validPos[data.clientUiPos])   and data.clientUiPos   or alertasCfg.ClientUI.position
    local npcPos  = (data.npcTripUiPos  and validPos[data.npcTripUiPos])  and data.npcTripUiPos  or alertasCfg.NpcTripUI.position
    local tnDur = tonumber(data.tripNotifyDur)
    if not tnDur or tnDur < 0 then tnDur = alertasCfg.TripNotify.duration end

    -- Actualizar memoria
    alertasCfg.TripNotify.position = tnPos
    alertasCfg.TripNotify.duration = tnDur
    alertasCfg.ClientUI.position   = cuPos
    alertasCfg.NpcTripUI.position  = npcPos

    -- Persistir si está habilitado en config
    if Config.AlertasConfig.TripNotify.persistent or Config.AlertasConfig.ClientUI.persistent then
        MySQL.update(
            'UPDATE `sh_taxijob_alertas_config` SET `trip_notify_pos`=?,`trip_notify_dur`=?,`client_ui_pos`=?,`npc_trip_ui_pos`=? WHERE `id`=1',
            {tnPos, tnDur, cuPos, npcPos}
        )
    end

    -- Notificar a todos los taxistas en servicio para que apliquen el nuevo layout.
    -- También incluir civiles con viaje activo (no tienen job pero sí UI de pasajero).
    local notifiedSources = {}
    for _,pid in ipairs(GetPlayers()) do
        pid=tonumber(pid)
        local pcid=GetCitizenId(pid)
        if pcid and HasAccess(pid) then
            TriggerClientEvent('sh-taxijob:client:receiveAlertasConfig',pid,{
                tripNotifyPos = tnPos,
                tripNotifyDur = tnDur,
                clientUiPos   = cuPos,
                npcTripUiPos  = npcPos,
            })
            notifiedSources[pid] = true
        end
    end
    -- Civiles con viaje activo que no tienen el job de taxi
    for _,trip in pairs(activeTrips) do
        local cSrc = trip.clientSrc
        if cSrc and not notifiedSources[cSrc] then
            notifiedSources[cSrc] = true
            TriggerClientEvent('sh-taxijob:client:receiveAlertasConfig',cSrc,{
                tripNotifyPos = tnPos,
                tripNotifyDur = tnDur,
                clientUiPos   = cuPos,
                npcTripUiPos  = npcPos,
            })
        end
    end

    TriggerClientEvent('sh-taxijob:client:notify',src,{
        type='success',title='Alertas Actualizadas',message='Los cambios se aplicaron a todos en servicio.'})
end)


RegisterNetEvent('sh-taxijob:server:updateTripConfig',function(cfg)
    local src=source; if not CanEdit(src,'viajes_config') then return end
    MySQL.update('UPDATE `sh_taxijob_trip_config` SET `base_price`=?,`price_per_unit`=?,`unit_meters`=?,`tip1`=?,`tip2`=?,`tip3`=?,`tip4`=? WHERE `id`=1',
        {tonumber(cfg.basePrice),tonumber(cfg.pricePerUnit),tonumber(cfg.unitMeters),
         tonumber(cfg.tips[1]),tonumber(cfg.tips[2]),tonumber(cfg.tips[3]),tonumber(cfg.tips[4])})
end)

RegisterNetEvent('sh-taxijob:server:updatePermission',function(grade,panel,allowed)
    local src=source; if not IsOwner(src) then return end
    grade=tonumber(grade)
    if not grade then return end
    if not panelPerms[grade] then panelPerms[grade]={} end
    panelPerms[grade][panel]=(allowed==true)
    -- Guardar inmediatamente en archivo JSON (persistente entre reinicios)
    SavePanelPerms()
    -- Broadcast a todos los owners con el estado completo actualizado
    local updatedPerms={}
    for g,_ in pairs(Config.DefaultPermissions) do
        updatedPerms[g]={}
        for p,v in pairs(Config.DefaultPermissions[g]) do updatedPerms[g][p]=v end
    end
    for g,panels in pairs(panelPerms) do
        if not updatedPerms[g] then updatedPerms[g]={} end
        for p,v in pairs(panels) do updatedPerms[g][p]=v end
    end
    for _,pid in ipairs(GetPlayers()) do
        pid=tonumber(pid)
        if IsOwner(pid) then
            TriggerClientEvent('sh-taxijob:client:permissionsUpdated',pid,updatedPerms)
        end
    end
end)

-- Obtener hotkeys
RegisterNetEvent('sh-taxijob:server:getHotkeys',function()
    local src=source; if not HasAccess(src) then return end
    MySQL.query('SELECT `slot`,`label`,`key` FROM `sh_taxijob_hotkeys` ORDER BY `slot` ASC',{},function(rows)
        TriggerClientEvent('sh-taxijob:client:receiveHotkeys',src,rows or {})
    end)
end)

-- Guardar hotkeys (solo propietario o quien puede editar panel hotkeys)
RegisterNetEvent('sh-taxijob:server:saveHotkeys',function(hotkeys)
    local src=source
    if not IsOwner(src) and not CanEdit(src,'hotkeys') then
        TriggerClientEvent('sh-taxijob:client:notify',src,{type='error',title='Sin permiso',message='No podés editar los accesos rápidos.'})
        return
    end
    if type(hotkeys)~='table' then return end
    for _,hk in ipairs(hotkeys) do
        local slot=tonumber(hk.slot)
        local key=(hk.key or ''):sub(1,8)
        local label=(hk.label or ''):sub(1,64)
        if slot and slot>=1 and slot<=6 then
            MySQL.query('INSERT INTO `sh_taxijob_hotkeys`(`slot`,`label`,`key`)VALUES(?,?,?) ON DUPLICATE KEY UPDATE `label`=?,`key`=?',
                {slot,label,key,label,key})
        end
    end
    TriggerClientEvent('sh-taxijob:client:notify',src,{type='success',title='Guardado',message='Accesos rápidos actualizados.'})
end)

RegisterNetEvent('sh-taxijob:server:getServiceLogs',function()
    local src=source; if not HasAccess(src) then return end
    -- Últimos 50 eventos de servicio
    MySQL.query('SELECT `player_name`,`action`,`log_time`,`duration` FROM `sh_taxijob_service_log` ORDER BY `log_time` DESC LIMIT '..Config.MaxServiceLogs,{},function(logs)
        TriggerClientEvent('sh-taxijob:client:receiveServiceLogs',src,logs or {})
    end)
end)

-- ─── CUENTA EMPRESA ─────────────────────────
RegisterNetEvent('sh-taxijob:server:getSocietyData',function()
    local src=source; if not HasAccess(src) then return end
    MySQL.query('SELECT `balance` FROM `sh_taxijob_society` WHERE `id`=1',{},function(bal)
        MySQL.query('SELECT `type`,`amount`,`description`,`done_by`,`created_at` FROM `sh_taxijob_society_log` ORDER BY `created_at` DESC LIMIT 10',{},function(logs)
            TriggerClientEvent('sh-taxijob:client:receiveSocietyData',src,{
                balance=bal and bal[1] and bal[1].balance or 0,
                logs=logs or {},
            })
        end)
    end)
end)

RegisterNetEvent('sh-taxijob:server:societyDeposit',function(amount)
    local src=source; if not CanEdit(src,'empresa') and not IsOwner(src) then return end
    amount=tonumber(amount); if not amount or amount<=0 then return end
    local ply=GetPlayer(src)
    if not ply then return end
    local bal=ply.PlayerData.money and ply.PlayerData.money.bank or 0
    if bal<amount then
        TriggerClientEvent('sh-taxijob:client:notify',src,{type='error',title='Sin fondos',message='No tenés $'..amount..' en el banco.'})
        return
    end
    ply.Functions.RemoveMoney('bank',amount,'taxijob-deposit')
    MySQL.query('UPDATE `sh_taxijob_society` SET `balance`=`balance`+? WHERE `id`=1',{amount})
    MySQL.insert('INSERT INTO `sh_taxijob_society_log`(`type`,`amount`,`description`,`done_by`,`created_at`)VALUES(?,?,?,?,?)',
        {'deposit',amount,'Depósito manual',GetPlayerName(src),os.time()})
    TriggerClientEvent('sh-taxijob:client:notify',src,{type='success',title='Depósito realizado',message='Depositaste $'..amount..' a la empresa.'})
    MySQL.query('SELECT `balance` FROM `sh_taxijob_society` WHERE `id`=1',{},function(b)
        MySQL.query('SELECT `type`,`amount`,`description`,`done_by`,`created_at` FROM `sh_taxijob_society_log` ORDER BY `created_at` DESC LIMIT 10',{},function(logs)
            TriggerClientEvent('sh-taxijob:client:receiveSocietyData',src,{balance=b and b[1] and b[1].balance or 0,logs=logs or {}})
        end)
    end)
end)

RegisterNetEvent('sh-taxijob:server:societyWithdraw',function(amount)
    local src=source; if not CanEdit(src,'empresa') and not IsOwner(src) then return end
    amount=tonumber(amount); if not amount or amount<=0 then return end
    MySQL.query('SELECT `balance` FROM `sh_taxijob_society` WHERE `id`=1',{},function(bal)
        local current=bal and bal[1] and bal[1].balance or 0
        if current<amount then
            TriggerClientEvent('sh-taxijob:client:notify',src,{type='error',title='Sin fondos',message='La empresa no tiene $'..amount..'.'})
            return
        end
        local ply=GetPlayer(src)
        if ply then ply.Functions.AddMoney('bank',amount,'taxijob-withdraw') end
        MySQL.query('UPDATE `sh_taxijob_society` SET `balance`=`balance`-? WHERE `id`=1',{amount})
        MySQL.insert('INSERT INTO `sh_taxijob_society_log`(`type`,`amount`,`description`,`done_by`,`created_at`)VALUES(?,?,?,?,?)',
            {'withdraw',-amount,'Retiro',GetPlayerName(src),os.time()})
        TriggerClientEvent('sh-taxijob:client:notify',src,{type='success',title='Retiro realizado',message='Retiraste $'..amount..' de la empresa.'})
        MySQL.query('SELECT `balance` FROM `sh_taxijob_society` WHERE `id`=1',{},function(b)
            MySQL.query('SELECT `type`,`amount`,`description`,`done_by`,`created_at` FROM `sh_taxijob_society_log` ORDER BY `created_at` DESC LIMIT 10',{},function(logs)
                TriggerClientEvent('sh-taxijob:client:receiveSocietyData',src,{balance=b and b[1] and b[1].balance or 0,logs=logs or {}})
            end)
        end)
    end)
end)

RegisterNetEvent('sh-taxijob:server:societyBonus',function(targetId,amount)
    local src=source; if not CanEdit(src,'empresa') and not IsOwner(src) then return end
    targetId=tonumber(targetId); amount=tonumber(amount)
    if not targetId or not amount or amount<=0 then return end
    MySQL.query('SELECT `balance` FROM `sh_taxijob_society` WHERE `id`=1',{},function(bal)
        local current=bal and bal[1] and bal[1].balance or 0
        if current<amount then
            TriggerClientEvent('sh-taxijob:client:notify',src,{type='error',title='Sin fondos',message='La empresa no tiene $'..amount..'.'})
            return
        end
        local tPly=GetPlayer(targetId)
        if not tPly then
            TriggerClientEvent('sh-taxijob:client:notify',src,{type='error',title='No encontrado',message='Jugador '..targetId..' no conectado.'})
            return
        end
        tPly.Functions.AddMoney('bank',amount,'taxijob-bonus')
        MySQL.query('UPDATE `sh_taxijob_society` SET `balance`=`balance`-? WHERE `id`=1',{amount})
        MySQL.insert('INSERT INTO `sh_taxijob_society_log`(`type`,`amount`,`description`,`done_by`,`created_at`)VALUES(?,?,?,?,?)',
            {'bonus',-amount,'Bono a '..GetPlayerName(targetId),GetPlayerName(src),os.time()})
        TriggerClientEvent('sh-taxijob:client:notify',targetId,{type='success',title='¡Bono recibido!',message='Recibiste un bono de $'..amount..' de la empresa.'})
        TriggerClientEvent('sh-taxijob:client:notify',src,{type='success',title='Bono enviado',message='Enviaste $'..amount..' de bono a '..GetPlayerName(targetId)..'.'})
        MySQL.query('SELECT `balance` FROM `sh_taxijob_society` WHERE `id`=1',{},function(b)
            MySQL.query('SELECT `type`,`amount`,`description`,`done_by`,`created_at` FROM `sh_taxijob_society_log` ORDER BY `created_at` DESC LIMIT 10',{},function(logs)
                TriggerClientEvent('sh-taxijob:client:receiveSocietyData',src,{balance=b and b[1] and b[1].balance or 0,logs=logs or {}})
            end)
        end)
    end)
end)

RegisterNetEvent('sh-taxijob:server:clearTripHistory',function()
    local src=source
    if not CanEdit(src,'viajes_realizados') and not IsOwner(src) then
        TriggerClientEvent('sh-taxijob:client:notify',src,{type='error',title='Sin permiso',message='No podés limpiar el historial.'})
        return
    end
    MySQL.query('DELETE FROM `sh_taxijob_trip_history`',{})
    TriggerClientEvent('sh-taxijob:client:notify',src,{type='success',title='Historial limpiado',message='El historial de viajes fue borrado.'})
end)

RegisterNetEvent('sh-taxijob:server:getTripHistory',function()
    local src=source; if not HasAccess(src) then return end
    -- Últimos 5 viajes finalizados
    MySQL.query('SELECT `driver_name`,`trip_cost`,`tip`,`meters`,`finished_at` FROM `sh_taxijob_trip_history` ORDER BY `finished_at` DESC LIMIT '..Config.MaxTripHistory,{},function(rows)
        TriggerClientEvent('sh-taxijob:client:receiveTripHistory',src,rows or {})
    end)
end)

-- ─── STASH / INVITAR / DESPEDIR ──────────────



RegisterNetEvent('sh-taxijob:server:openStash',function()
    local src=source; if not HasAccess(src) then return end
    if ActiveInventory=='ox_inventory' then
        -- forceOpenInventory es la función correcta del server-side de ox_inventory
        exports.ox_inventory:forceOpenInventory(src, 'stash', Config.StashName)
    else
        -- qb-inventory: OpenInventory se llama server-side con los datos del stash
        exports['qb-inventory']:OpenInventory(src, Config.StashName, {
            label     = Config.StashLabel  or 'Almacén Taxi',
            maxweight = Config.StashWeight or 100000,
            slots     = Config.StashSlots  or 50,
        })
    end
end)

RegisterNetEvent('sh-taxijob:server:inviteById',function(targetId,grade)
    local src=source; if not CanEdit(src,'invitar') then return end
    targetId=tonumber(targetId); if not targetId then return end
    grade=tonumber(grade) or 0
    local tcid=GetCitizenId(targetId)
    if not tcid then
        TriggerClientEvent('sh-taxijob:client:notify',src,{type='error',title='No encontrado',message='ID '..targetId..' no conectado.'})
        return
    end
    local gLabel=(Config.Grades[grade] or {label='Conductor'}).label
    members[tcid]=grade
    local tname=GetPlayerName(targetId)
    memberNames[tcid]=tname
    MySQL.query('INSERT INTO `sh_taxijob_members`(`citizenid`,`is_owner`,`grade`,`player_name`,`given_by`)VALUES(?,0,?,?,?) ON DUPLICATE KEY UPDATE `is_owner`=0,`grade`=?,`player_name`=?,`given_by`=?',
        {tcid,grade,tname,GetPlayerName(src),grade,tname,GetPlayerName(src)})
    TriggerClientEvent('sh-taxijob:client:notify',targetId,{type='success',title='¡Bienvenido!',message='Sos del Taxi como '..gLabel..'. Usá /taxijob.'})
    TriggerClientEvent('sh-taxijob:client:notify',src,{type='success',title='Invitado',message=GetPlayerName(targetId)..' invitado como '..gLabel..'.'})
    TriggerClientEvent('sh-taxijob:client:receivePermission',targetId,{hasAccess=true,isOwner=false,onDuty=false,msToNext=salaryMs})
end)

RegisterNetEvent('sh-taxijob:server:inviteNearby',function(grade)
    local src=source; if not CanEdit(src,'invitar') then return end
    grade=tonumber(grade) or 0
    local sc=GetEntityCoords(GetPlayerPed(src))
    local nearest,nd=nil,5.0
    for _,pid in ipairs(GetPlayers()) do
        pid=tonumber(pid); if pid~=src then
            local d=#(sc-GetEntityCoords(GetPlayerPed(pid)))
            if d<nd then nd=d;nearest=pid end
        end
    end
    if not nearest then
        TriggerClientEvent('sh-taxijob:client:notify',src,{type='error',title='Sin jugadores',message='Nadie cerca (5m).'})
        return
    end
    local ncid=GetCitizenId(nearest)
    if ncid then
        members[ncid]=grade
        local nname=GetPlayerName(nearest)
        memberNames[ncid]=nname
        MySQL.query('INSERT INTO `sh_taxijob_members`(`citizenid`,`is_owner`,`grade`,`player_name`,`given_by`)VALUES(?,0,?,?,?) ON DUPLICATE KEY UPDATE `is_owner`=0,`grade`=?,`player_name`=?,`given_by`=?',
            {ncid,grade,nname,GetPlayerName(src),grade,nname,GetPlayerName(src)})
    end
    local gLabel=(Config.Grades[grade] or {label='Conductor'}).label
    TriggerClientEvent('sh-taxijob:client:notify',nearest,{type='success',title='¡Bienvenido!',message='Sos del Taxi como '..gLabel..'. Usá /taxijob.'})
    TriggerClientEvent('sh-taxijob:client:notify',src,{type='success',title='Invitado',message=GetPlayerName(nearest)..' invitado.'})
    TriggerClientEvent('sh-taxijob:client:receivePermission',nearest,{hasAccess=true,isOwner=false,onDuty=false,msToNext=salaryMs})
end)

RegisterNetEvent('sh-taxijob:server:changeGrade',function(targetId,newGrade)
    local src=source; if not IsOwner(src) then return end
    targetId=tonumber(targetId); newGrade=tonumber(newGrade)
    if not targetId or not newGrade then return end
    local tcid=GetCitizenId(targetId)
    if tcid and members[tcid]~=nil then members[tcid]=newGrade end
    MySQL.query('UPDATE `sh_taxijob_members` SET `grade`=? WHERE `citizenid`=?',{newGrade,tcid})
    local gLabel=(Config.Grades[newGrade] or {label='Conductor'}).label
    TriggerClientEvent('sh-taxijob:client:notify',targetId,{type='info',title='Rango',message='Tu rango cambió a '..gLabel..'.'})
    TriggerClientEvent('sh-taxijob:client:notify',src,{type='success',title='Cambiado',message=GetPlayerName(targetId)..' ahora es '..gLabel..'.'})
end)

RegisterNetEvent('sh-taxijob:server:fireEmployee',function(targetId)
    local src=source; if not IsOwner(src) then return end
    targetId=tonumber(targetId); if not targetId then return end
    local tcid=GetCitizenId(targetId)
    if tcid then
        members[tcid]=nil; owners[tcid]=nil
        onDuty[tcid]=nil; nextPay[tcid]=nil; dutyStart[tcid]=nil
        MySQL.query('DELETE FROM `sh_taxijob_members` WHERE `citizenid`=?',{tcid})
    end
    TriggerClientEvent('sh-taxijob:client:notify',targetId,{type='error',title='Despedido',message='Fuiste removido del Taxi.'})
    TriggerClientEvent('sh-taxijob:client:receivePermission',targetId,{hasAccess=false,isOwner=false,onDuty=false,msToNext=0})
    TriggerClientEvent('sh-taxijob:client:notify',src,{type='success',title='Removido',message=GetPlayerName(targetId)..' fue despedido.'})
end)

-- ─── SPAWN / DESPAWN ─────────────────────────
local spawnedVehicles={}

-- Obtener datos de compra de vehículos
local function SendVehiclePurchasesToClient(src)
    MySQL.query('SELECT `vehicle_model`,`purchased` FROM `sh_taxijob_vehicle_purchases`',{},function(result)
        local vehPurch={}
        if result then
            for _,v in ipairs(result) do
                -- Convertir a boolean correctamente (puede venir como 1, true, "true", etc)
                local isPurchased = v.purchased == 1 or v.purchased == true or tostring(v.purchased):lower() == 'true'
                vehPurch[v.vehicle_model] = isPurchased
            end
        end
        TriggerClientEvent('sh-taxijob:client:updateVehiclePurchases',src,vehPurch)
    end)
end

RegisterNetEvent('sh-taxijob:server:requestVehiclePurchases',function()
    SendVehiclePurchasesToClient(source)
end)

-- Comprar vehículo
RegisterNetEvent('sh-taxijob:server:buyVehicle',function(model)
    local src=source
    
    if not HasAccess(src) then return end
    
    if not CanEdit(src,'vehiculos') and not IsOwner(src) then
        TriggerClientEvent('sh-taxijob:client:notify',src,{type='error',title='Sin permiso',message='No podés comprar vehículos.'})
        return
    end
    
    -- Validar que estés de servicio
    local cid=GetCitizenId(src)
    if not cid or not onDuty[cid] then
        TriggerClientEvent('sh-taxijob:client:notify',src,{type='error',title='Sin Servicio',message='Debes estar de servicio para comprar vehículos.'})
        return
    end
    
    -- Verificar vehículo en config
    local vehicleConfig=nil
    for _,v in ipairs(Config.SpawnVehicles) do
        if v.model==model then vehicleConfig=v; break end
    end
    if not vehicleConfig then
        TriggerClientEvent('sh-taxijob:client:notify',src,{type='error',title='Error',message='Vehículo no válido en config.'})
        return
    end
    
    -- Verificar vehículo en BD
    MySQL.query('SELECT `id`,`price`,`purchased` FROM `sh_taxijob_vehicle_purchases` WHERE `vehicle_model`=?',{model},function(result)
        if not result or not result[1] then
            TriggerClientEvent('sh-taxijob:client:notify',src,{type='error',title='Error',message='Vehículo no encontrado en BD.'})
            return
        end
        
        local vehId=result[1].id
        local price=result[1].price or 0
        local purchased=result[1].purchased
        
        -- Comparar correctamente
        local isPurchased = purchased == 1 or purchased == true or tostring(purchased):lower() == 'true'
        if isPurchased then
            TriggerClientEvent('sh-taxijob:client:notify',src,{type='warning',title='Ya comprado',message='Este vehículo ya fue comprado.'})
            return
        end
        
        if price==0 then
            MySQL.query('UPDATE `sh_taxijob_vehicle_purchases` SET `purchased`=1 WHERE `id`=?',{vehId},function()
                TriggerClientEvent('sh-taxijob:client:notify',src,{type='info',title='Sin costo',message='Este vehículo está disponible sin costo.'})
                TriggerClientEvent('sh-taxijob:client:refreshTablet',src)
                SendVehiclePurchasesToClient(src)
            end)
            return
        end
        
        -- Verificar balance
        MySQL.query('SELECT `balance` FROM `sh_taxijob_society` WHERE `id`=1',{},function(balResult)
            local current=balResult and balResult[1] and balResult[1].balance or 0
            
            if current<price then
                TriggerClientEvent('sh-taxijob:client:notify',src,{type='error',title='Sin fondos',message='La empresa no tiene $'..price..' para comprar este vehículo.'})
                return
            end
            
            -- Descontar del balance
            MySQL.query('UPDATE `sh_taxijob_society` SET `balance`=`balance`-? WHERE `id`=1',{price},function()
                -- Agregar log
                MySQL.query('INSERT INTO `sh_taxijob_society_log`(`type`,`amount`,`description`,`done_by`,`created_at`)VALUES(?,?,?,?,?)',
                    {'purchase',-price,'Compra vehículo: '..model,GetPlayerName(src),os.time()},function()
                end)
                
                -- Marcar como comprado
                MySQL.query('UPDATE `sh_taxijob_vehicle_purchases` SET `purchased`=1 WHERE `id`=?',{vehId},function()
                    -- Notificar éxito
                    TriggerClientEvent('sh-taxijob:client:notify',src,{type='success',title='Comprado!',message='Vehículo '..model..' comprado por $'..price..'.'})
                    
                    -- Actualizar cliente
                    TriggerClientEvent('sh-taxijob:client:refreshTablet',src)
                    SendVehiclePurchasesToClient(src)
                end)
            end)
        end)
    end)
end)

RegisterNetEvent('sh-taxijob:server:spawnVehicle',function(model)
    local src=source
    if not HasAccess(src) then return end
    
    -- Validar que el vehículo existe en config
    local vehicleConfig=nil
    for _,v in ipairs(Config.SpawnVehicles) do
        if v.model==model then vehicleConfig=v; break end
    end
    if not vehicleConfig then
        TriggerClientEvent('sh-taxijob:client:notify',src,{type='error',title='Error',message='Vehículo no válido.'})
        return
    end
    
    -- Validar XP y compra
    local cid=GetCitizenId(src)
    if not cid then
        TriggerClientEvent('sh-taxijob:client:notify',src,{type='error',title='Error',message='No se pudo obtener ciudadano.'})
        return
    end
    
    -- Obtener nivel XP
    local xpData=MySQL.query.await('SELECT `level` FROM `sh_taxijob_xp` WHERE `citizenid`=?',{cid})
    local level=xpData and xpData[1] and xpData[1].level or 0
    if level<vehicleConfig.minLevel then
        TriggerClientEvent('sh-taxijob:client:notify',src,{type='error',title='Nivel insuficiente',message='Necesitas nivel '..vehicleConfig.minLevel..' para este vehículo.'})
        return
    end
    
    -- Obtener estado de compra
    local vehData=MySQL.query.await('SELECT `purchased` FROM `sh_taxijob_vehicle_purchases` WHERE `vehicle_model`=?',{model})
    if not vehData or not vehData[1] then
        TriggerClientEvent('sh-taxijob:client:notify',src,{type='error',title='Error',message='Vehículo no encontrado en compras.'})
        return
    end
    -- Comparar correctamente (puede venir como 1, true, "true", etc)
    local isPurchased = vehData[1].purchased == 1 or vehData[1].purchased == true or tostring(vehData[1].purchased):lower() == 'true'
    if not isPurchased then
        TriggerClientEvent('sh-taxijob:client:notify',src,{type='error',title='No comprado',message='Debes comprar este vehículo primero.'})
        return
    end
    
    -- Ambas condiciones OK, proceder con spawn
    if spawnedVehicles[src] then
        TriggerClientEvent('sh-taxijob:client:deleteVehicle',src,spawnedVehicles[src])
        spawnedVehicles[src]=nil
    end
    TriggerClientEvent('sh-taxijob:client:doSpawnVehicle',src,model)
end)

RegisterNetEvent('sh-taxijob:server:registerVehicle',function(netId) spawnedVehicles[source]=netId end)
RegisterNetEvent('sh-taxijob:server:despawnVehicle',function()
    local src=source
    if spawnedVehicles[src] then
        TriggerClientEvent('sh-taxijob:client:deleteVehicle',src,spawnedVehicles[src])
        spawnedVehicles[src]=nil
    end
end)

-- Obtener nombre real de offline
RegisterNetEvent('sh-taxijob:server:getOfflineNames',function(cids)
    local src=source; if not HasAccess(src) then return end
    -- Intentar obtener nombres desde players offline según framework
    -- QBCore guarda en DB
    if Framework=='qbcore' and QBCore then
        local result={}
        local pending=#cids
        if pending==0 then TriggerClientEvent('sh-taxijob:client:receiveOfflineNames',src,result); return end
        for _,cid in ipairs(cids) do
            MySQL.query('SELECT `charinfo` FROM `players` WHERE `citizenid`=?',{cid},function(r)
                if r and r[1] then
                    local ok,ci=pcall(json.decode,r[1].charinfo)
                    if ok and ci then result[cid]=(ci.firstname or '')..' '..(ci.lastname or '')
                    else result[cid]=cid end
                else result[cid]=cid end
                pending=pending-1
                if pending<=0 then TriggerClientEvent('sh-taxijob:client:receiveOfflineNames',src,result) end
            end)
        end
    else
        local result={}
        for _,cid in ipairs(cids) do result[cid]=cid end
        TriggerClientEvent('sh-taxijob:client:receiveOfflineNames',src,result)
    end
end)

-- ─── NOMBRE EMPRESA ───────────────────────────
RegisterNetEvent('sh-taxijob:server:getCompanyName',function()
    local src=source
    MySQL.query('SELECT `company_name` FROM `sh_taxijob_company` WHERE `id`=1',{},function(r)
        local name=(r and r[1] and r[1].company_name) or 'Taxi Corp'
        TriggerClientEvent('sh-taxijob:client:receiveCompanyName',src,name)
    end)
end)

RegisterNetEvent('sh-taxijob:server:setCompanyName',function(name)
    local src=source
    if not IsOwner(src) then
        TriggerClientEvent('sh-taxijob:client:notify',src,{type='error',title='Sin permiso',message='Solo el propietario puede cambiar el nombre.'})
        return
    end
    name=tostring(name or 'Taxi Corp'):sub(1,64)
    if name=='' then name='Taxi Corp' end
    MySQL.query('UPDATE `sh_taxijob_company` SET `company_name`=? WHERE `id`=1',{name},function()
        -- Broadcast a todos los miembros online
        for _,pid in ipairs(GetPlayers()) do
            pid=tonumber(pid)
            if HasAccess(pid) then
                TriggerClientEvent('sh-taxijob:client:receiveCompanyName',pid,name)
            end
        end
        TriggerClientEvent('sh-taxijob:client:notify',src,{type='success',title='Guardado',message='Nombre actualizado a: '..name})
    end)
end)

-- ─── NOTAS ────────────────────────────────────
RegisterNetEvent('sh-taxijob:server:getNotes',function()
    local src=source
    if not HasAccess(src) then return end
    MySQL.query('SELECT `citizenid`,`player_name`,`note`,`updated_at` FROM `sh_taxijob_notes` ORDER BY `updated_at` DESC',{},function(rows)
        TriggerClientEvent('sh-taxijob:client:receiveNotes',src,rows or {})
    end)
end)

RegisterNetEvent('sh-taxijob:server:saveNote',function(note)
    local src=source
    if not HasAccess(src) then return end
    local cid=GetCitizenId(src)
    if not cid then return end
    note=tostring(note or ''):sub(1,300)
    local name=GetPlayerName(src)
    local now=os.time()
    MySQL.query('INSERT INTO `sh_taxijob_notes`(`citizenid`,`player_name`,`note`,`updated_at`)VALUES(?,?,?,?) ON DUPLICATE KEY UPDATE `note`=?,`player_name`=?,`updated_at`=?',
        {cid,name,note,now,note,name,now},function()
        -- Broadcast a todos los miembros online
        local entry={citizenid=cid,player_name=name,note=note,updated_at=now}
        for _,pid in ipairs(GetPlayers()) do
            pid=tonumber(pid)
            if HasAccess(pid) then
                TriggerClientEvent('sh-taxijob:client:noteUpdated',pid,entry)
            end
        end
    end)
end)

RegisterNetEvent('sh-taxijob:server:deleteNote',function(targetCid)
    local src=source
    if not HasAccess(src) then return end
    local myCid=GetCitizenId(src)
    if not myCid then return end

    -- Si se pasa un targetCid distinto al propio, solo propietarios/grade>=3 pueden borrar notas ajenas
    local cidToDelete = targetCid or myCid
    if cidToDelete ~= myCid then
        -- Solo propietario o grado >= 3 puede borrar notas ajenas
        local grade = GetMemberGrade(src)
        if not IsOwner(src) and grade < 3 then
            TriggerClientEvent('sh-taxijob:client:notify',src,{type='error',title='Sin permiso',message='Solo supervisores o superiores pueden eliminar notas ajenas.'})
            return
        end
    end

    MySQL.query('DELETE FROM `sh_taxijob_notes` WHERE `citizenid`=?',{cidToDelete},function()
        for _,pid in ipairs(GetPlayers()) do
            pid=tonumber(pid)
            if HasAccess(pid) then
                TriggerClientEvent('sh-taxijob:client:noteDeleted',pid,cidToDelete)
            end
        end
    end)
end)

-- Colocar/quitar nota de pizarra (DrawText) — el servidor retransmite a todos del job
local boardNotes = {}  -- cid → {text, x, y, z}

RegisterNetEvent('sh-taxijob:server:placeBoardNote',function(text,x,y,z)
    local src=source
    if not HasAccess(src) then return end
    local cid=GetCitizenId(src)
    if not cid then return end
    text=tostring(text or ''):sub(1,200)
    boardNotes[cid]={text=text,x=x,y=y,z=z,name=GetPlayerName(src)}
    for _,pid in ipairs(GetPlayers()) do
        pid=tonumber(pid)
        if HasAccess(pid) then
            TriggerClientEvent('sh-taxijob:client:boardNoteAdded',pid,cid,boardNotes[cid])
        end
    end
end)

RegisterNetEvent('sh-taxijob:server:removeBoardNote',function()
    local src=source
    if not HasAccess(src) then return end
    local cid=GetCitizenId(src)
    if not cid then return end
    boardNotes[cid]=nil
    for _,pid in ipairs(GetPlayers()) do
        pid=tonumber(pid)
        if HasAccess(pid) then
            TriggerClientEvent('sh-taxijob:client:boardNoteRemoved',pid,cid)
        end
    end
end)

RegisterNetEvent('sh-taxijob:server:requestBoardNotes',function()
    local src=source
    if not HasAccess(src) then return end
    TriggerClientEvent('sh-taxijob:client:receiveBoardNotes',src,boardNotes)
end)


AddEventHandler('playerDropped', function()
    local src = source
    local cid = GetCitizenId(src)

    if cid then
        if onDuty[cid] then
            local dur = dutyStart[cid] and (os.time()-dutyStart[cid]) or 0
            MySQL.insert('INSERT INTO `sh_taxijob_service_log`(`citizenid`,`player_name`,`action`,`log_time`,`duration`)VALUES(?,?,?,?,?)',
                {cid,'(desconectado)','stop',os.time(),dur})
        end

        onDuty[cid] = nil
        nextPay[cid] = nil
        dutyStart[cid] = nil

        -- Si tenía viaje activo, cancelarlo
        if driverTrips[cid] then
            local tripId = driverTrips[cid]
            local trip = activeTrips[tripId]

            if trip then
                trip.status = 'cancelled'
                MySQL.update('UPDATE `sh_taxijob_trips` SET `status`=? WHERE `id`=?',{'cancelled',tripId})

                TriggerClientEvent('sh-taxijob:client:notify',trip.clientSrc,{
                    type='error',
                    title='Viaje cancelado',
                    message='Tu taxista se desconectó. Pedí otro taxi.'
                })

                TriggerClientEvent('sh-taxijob:client:tripCancelledDriver',trip.clientSrc)

                clientTrips[trip.clientCid] = nil
                activeTrips[tripId] = nil
            end

            driverTrips[cid] = nil
        end

        if clientTrips[cid] then
            local tripId = clientTrips[cid]
            local trip = activeTrips[tripId]

            if trip then
                trip.status = 'cancelled'
                MySQL.update('UPDATE `sh_taxijob_trips` SET `status`=? WHERE `id`=?',{'cancelled',tripId})

                if trip.driverCid then
                    driverTrips[trip.driverCid] = nil
                end

                activeTrips[tripId] = nil
            end

            clientTrips[cid] = nil
        end
    end

    spawnedVehicles[src] = nil

    -- Limpiar radio al desconectarse
    if cid then
        for i=1,5 do
            if radioChannels[i] and radioChannels[i].members[cid] then
                radioChannels[i].members[cid]=nil
            end
        end
        -- Broadcast radio y lista de servicio actualizada
        Citizen.SetTimeout(200, function()
            BroadcastRadio()
            for _,pid in ipairs(GetPlayers()) do
                pid=tonumber(pid)
                if HasAccess(pid) then
                    TriggerClientEvent('sh-taxijob:client:radioOnDuty',pid,GetOnDutyList())
                end
            end
        end)
    end
end)

-- ─── SINCRONIZAR VEHÍCULOS CON CONFIG ───────────────────────
CreateThread(function()
    -- Esperar a que InstallSQL haya creado todas las tablas
    while not sqlReady do Wait(200) end
    for _, v in ipairs(Config.SpawnVehicles) do
        local result = MySQL.query.await('SELECT `id` FROM `sh_taxijob_vehicle_purchases` WHERE `vehicle_model`=?', {v.model})
        if not result or #result == 0 then
            MySQL.insert('INSERT INTO `sh_taxijob_vehicle_purchases`(`vehicle_model`,`label`,`price`,`purchased`)VALUES(?,?,?,?)',
                {v.model, v.label, v.price, 0})
            DBG('^3[sh-taxijob]^0 Vehículo agregado a BD: ' .. v.model)
        end
    end
    DBG('^2[sh-taxijob]^0 Sincronización de vehículos completada.')
end)

-- ─── SISTEMA DE RADIO — EVENTOS ─────────────
local pitarCooldowns = {}

-- Solicitar estado actual (al abrir el panel)
RegisterNetEvent('sh-taxijob:server:getRadioState',function()
    local src=source
    if not HasAccess(src) then return end
    TriggerClientEvent('sh-taxijob:client:radioState',src,GetRadioState())
    TriggerClientEvent('sh-taxijob:client:radioOnDuty',src,GetOnDutyList())
end)

-- Entrar/salir de un canal
RegisterNetEvent('sh-taxijob:server:joinRadioChannel',function(slot)
    local src=source
    if not HasAccess(src) then return end
    local cid=GetCitizenId(src)
    if not cid then return end
    if not onDuty[cid] then
        TriggerClientEvent('sh-taxijob:client:notify',src,{type='error',title='Radio',message='Debés estar en servicio para usar la radio.'})
        return
    end
    slot=tonumber(slot)
    if not slot or slot<1 or slot>5 then return end

    local name=GetPlayerName(src)
    local ch=radioChannels[slot]

    -- Si ya está en ese canal, salir
    if ch.members[cid] then
        ch.members[cid]=nil
        -- Decirle al CLIENTE que se desconecte de pma-voice (freq=0 = salir)
        TriggerClientEvent('sh-taxijob:client:setRadioFreq',src,0)
        TriggerClientEvent('sh-taxijob:client:notify',src,{type='info',title='Radio',message='Saliste del canal '..slot..' (Freq: '..ch.freq..')'})
    else
        -- Salir de cualquier otro canal donde esté
        for i=1,5 do
            if radioChannels[i].members[cid] then
                radioChannels[i].members[cid]=nil
            end
        end
        -- Entrar al nuevo canal
        ch.members[cid]={name=name,src=src}
        -- Decirle al CLIENTE que sintonice la frecuencia en pma-voice
        TriggerClientEvent('sh-taxijob:client:setRadioFreq',src,ch.freq)
        TriggerClientEvent('sh-taxijob:client:notify',src,{type='success',title='Radio',message='Entraste al canal '..slot..' (Freq: '..ch.freq..')'})
    end
    BroadcastRadio()
end)

-- Cambiar frecuencia de un canal (solo propietario o grade>=3)
RegisterNetEvent('sh-taxijob:server:setRadioFreq',function(slot,freq)
    local src=source
    if not HasAccess(src) then return end
    local grade=GetMemberGrade(src)
    if not IsOwner(src) and grade<3 then
        TriggerClientEvent('sh-taxijob:client:notify',src,{type='error',title='Radio',message='Sin permiso para cambiar frecuencias.'})
        return
    end
    slot=tonumber(slot); freq=tonumber(freq)
    if not slot or slot<1 or slot>5 then return end
    if not freq or freq<3000 or freq>9999 then
        TriggerClientEvent('sh-taxijob:client:notify',src,{type='error',title='Radio',message='Frecuencia inválida (3000-9999).'})
        return
    end
    local ch=radioChannels[slot]
    ch.freq=freq
    -- Notificar a cada miembro del canal que cambie su frecuencia en pma-voice
    for _cid,m in pairs(ch.members) do
        TriggerClientEvent('sh-taxijob:client:setRadioFreq',m.src,freq)
    end
    BroadcastRadio()
    TriggerClientEvent('sh-taxijob:client:notify',src,{type='success',title='Radio',message='Canal '..slot..' → frecuencia '..freq})
end)

-- Pitar radio a un jugador específico (cooldown 5s por par)
RegisterNetEvent('sh-taxijob:server:pitarRadio',function(targetSrc)
    local src=source
    if not HasAccess(src) then return end
    local cid=GetCitizenId(src)
    if not cid then return end
    if not onDuty[cid] then
        TriggerClientEvent('sh-taxijob:client:notify',src,{type='error',title='Radio',message='Debés estar de servicio.'})
        return
    end
    targetSrc=tonumber(targetSrc)
    if not targetSrc or not GetPlayerName(targetSrc) then return end
    local tcid=GetCitizenId(targetSrc)
    if not tcid or not HasAccess(targetSrc) then return end

    local key=src..'_'..targetSrc
    local now=os.time()
    if pitarCooldowns[key] and (now-pitarCooldowns[key])<5 then
        local left=5-(now-pitarCooldowns[key])
        TriggerClientEvent('sh-taxijob:client:notify',src,{type='warning',title='Radio',message='Esperá '..left..'s para pitar de nuevo.'})
        return
    end
    pitarCooldowns[key]=now
    -- Notificar al objetivo
    TriggerClientEvent('sh-taxijob:client:notify',targetSrc,{
        type='warning',title='📻 Radio',
        message=GetPlayerName(src)..' te está pitando la radio.'
    })
    -- Confirmar al que pita
    TriggerClientEvent('sh-taxijob:client:notify',src,{type='info',title='Radio',message='Pitaste a '..GetPlayerName(targetSrc)..'.'})
end)

-- Al cambiar duty, broadcast radio actualizada y lista de servicio
local _origToggleDuty = nil  -- solo agregamos broadcast extra
AddEventHandler('sh-taxijob:server:dutyChanged',function()
    BroadcastRadio()
    for _,pid in ipairs(GetPlayers()) do
        pid=tonumber(pid)
        if HasAccess(pid) then
            TriggerClientEvent('sh-taxijob:client:radioOnDuty',pid,GetOnDutyList())
        end
    end
end)

-- Limpiar radio al desconectarse
local _origPlayerDropped = AddEventHandler  -- solo hook extra
AddEventHandler('sh-taxijob:internal:playerDroppedRadio',function(src,cid)
    for i=1,5 do
        if radioChannels[i].members[cid] then
            radioChannels[i].members[cid]=nil
        end
    end
    BroadcastRadio()
end)

-- =============================================
--   NPC MISSIONS (fusionado desde server_npcmissions.lua)
-- =============================================

-- ─── Framework helpers locales NPC ───────────
-- (server.lua ya detectó el framework, pero sus vars son locales.
--  Redefinimos aquí de forma independiente.)
local QBCore_NM, QBX_NM
local Framework_NM = 'none'

Citizen.CreateThread(function()
    Citizen.Wait(1000)
    if     GetResourceState('qbx_core') == 'started' then
        Framework_NM = 'qbox';   QBX_NM = exports['qbx_core']
    elseif GetResourceState('qb-core')  == 'started' then
        Framework_NM = 'qbcore'; QBCore_NM = exports['qb-core']:GetCoreObject()
    end
end)

local function NM_GetPlayer(src)
    if     Framework_NM == 'qbox'   then return QBX_NM:GetPlayer(src)
    elseif Framework_NM == 'qbcore' then return QBCore_NM.Functions.GetPlayer(src) end
    return nil
end
local function NM_GetCid(src)
    local p = NM_GetPlayer(src); if not p then return nil end
    return p.PlayerData.citizenid
end
local function NM_GetName(src)
    local p = NM_GetPlayer(src); if not p then return 'NPC Driver' end
    local ci = p.PlayerData.charinfo
    return ((ci and ci.firstname) or '') .. ' ' .. ((ci and ci.lastname) or '')
end
local function NM_AddMoney(src, amount, reason)
    local p = NM_GetPlayer(src); if not p then return end
    p.Functions.AddMoney('bank', amount, reason or 'npc-mission')
end

-- ─── Estado en memoria ───────────────────────
local activeMissions    = {}   -- [cid] = { missionId, gradeKey, startTime, src }
local playerMissionCache = {}  -- [cid] = { missions, generatedAt }  ← FIX cache

-- ─── SQL: crear tablas si no existen ─────────
local function InstallNpcSQL()
    MySQL.query([[
        CREATE TABLE IF NOT EXISTS `sh_taxijob_daily_missions` (
            `id`          INT NOT NULL AUTO_INCREMENT,
            `citizenid`   VARCHAR(64) NOT NULL,
            `grade_key`   VARCHAR(32) NOT NULL,
            `mission_idx` INT NOT NULL DEFAULT 0,
            `status`      VARCHAR(16) NOT NULL DEFAULT 'pending',
            `reset_at`    BIGINT NOT NULL DEFAULT 0,
            `created_at`  BIGINT NOT NULL DEFAULT 0,
            `finished_at` BIGINT DEFAULT NULL,
            `final_pay`   INT NOT NULL DEFAULT 0,
            `runaway`     TINYINT(1) NOT NULL DEFAULT 0,
            PRIMARY KEY(`id`), INDEX(`citizenid`), INDEX(`reset_at`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]])
    MySQL.query([[
        CREATE TABLE IF NOT EXISTS `sh_taxijob_daily_timer` (
            `citizenid` VARCHAR(64) NOT NULL,
            `reset_at`  BIGINT NOT NULL DEFAULT 0,
            PRIMARY KEY(`citizenid`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]])
    DBG('^2[sh-taxijob-npc]^0 Tablas de misiones NPC listas.')
end
AddEventHandler('onResourceStart', function(res)
    if res ~= GetCurrentResourceName() then return end
    Citizen.SetTimeout(2500, InstallNpcSQL)
end)
InstallNpcSQL()

-- ─── Helpers ─────────────────────────────────
local function GetPlayerLevel(cid, cb)
    MySQL.query('SELECT `level` FROM `sh_taxijob_xp` WHERE `citizenid`=?', { cid }, function(r)
        cb(r and r[1] and r[1].level or 0)
    end)
end

local function GetAvailableGrades(level)
    local bestKey = 0
    for lvl, _ in pairs(Config.MissionMixChances) do
        if lvl <= level and lvl >= bestKey then bestKey = lvl end
    end
    local mix = Config.MissionMixChances[bestKey]
    if not mix then mix = { { grade='Basico', chance=1.0 } } end
    return mix
end

local function GenerateMissionList(level)
    local mix      = GetAvailableGrades(level)
    local maxCount = Config.DailyMissionMaxVisible or 10
    local result   = {}
    for i = 1, maxCount do
        local r = math.random(); local cumul = 0.0; local chosen = mix[1].grade
        for _, entry in ipairs(mix) do
            cumul = cumul + entry.chance
            if r <= cumul then chosen = entry.grade; break end
        end
        local gradeCfg = Config.MissionGrades[chosen]
        if gradeCfg and level >= gradeCfg.levelRequired then
            local points = Config.MissionPoints[chosen]
            if points and #points > 0 then
                local pt      = points[math.random(#points)]
                local peds    = Config.MissionPeds[chosen] or Config.MissionPeds['Basico']
                local ped     = peds[math.random(#peds)]
                local basePay  = math.floor((Config.NpcMissionBasePay or 100)
                               * (gradeCfg.baseMultiplier or 1.0)
                               * (gradeCfg.payMultiplier  or 1.0))
                local xpReward = math.floor((Config.NpcMissionBaseXp or 50)
                               * (gradeCfg.baseMultiplier or 1.0))
                local dist    = #(vector3(pt.pickup.x, pt.pickup.y, pt.pickup.z) -
                                  vector3(pt.dropoff.x, pt.dropoff.y, pt.dropoff.z))
                table.insert(result, {
                    id=i, gradeKey=chosen, gradeLabel=gradeCfg.label or chosen,
                    gradeColor=gradeCfg.color or '#9b59b6',
                    pickupX=pt.pickup.x, pickupY=pt.pickup.y, pickupZ=pt.pickup.z, pickupH=pt.pickup.w or 0.0,
                    dropX=pt.dropoff.x, dropY=pt.dropoff.y, dropZ=pt.dropoff.z,
                    pedModel=ped, basePay=basePay, xpReward=xpReward, distMeters=math.floor(dist),
                    hasTimer=gradeCfg.hasTimer or false, timerSecs=gradeCfg.timerSeconds or 0,
                    bonusPct=gradeCfg.bonusPct or 0,
                    hasProbRunaway=gradeCfg.hasProbRunaway or false, runawayChance=gradeCfg.runawayChance or 0.0,
                })
            end
        end
    end
    return result
end

local function GetOrCreateDailyTimer(cid, cb)
    local now = os.time() * 1000
    MySQL.query('SELECT `reset_at` FROM `sh_taxijob_daily_timer` WHERE `citizenid`=?', { cid }, function(r)
        if r and r[1] and r[1].reset_at > now then
            cb(r[1].reset_at - now, false)
        else
            local resetAt = now + (Config.DailyMissionResetSeconds or 86400) * 1000
            MySQL.query(
                'INSERT INTO `sh_taxijob_daily_timer`(`citizenid`,`reset_at`) VALUES(?,?) ON DUPLICATE KEY UPDATE `reset_at`=?',
                { cid, resetAt, resetAt }, function() cb(resetAt - now, true) end)
        end
    end)
end

local function SaveMissionsForPlayer(cid, missions, resetAt)
    MySQL.query('DELETE FROM `sh_taxijob_daily_missions` WHERE `citizenid`=? AND `status`=?', { cid, 'pending' },
    function()
        for _, m in ipairs(missions) do
            MySQL.insert(
                'INSERT INTO `sh_taxijob_daily_missions`(`citizenid`,`grade_key`,`mission_idx`,`status`,`reset_at`,`created_at`)VALUES(?,?,?,?,?,?)',
                { cid, m.gradeKey, m.id, 'pending', resetAt, os.time() * 1000 })
        end
    end)
end

-- ─── Pedir misiones diarias ───────────────────
RegisterNetEvent('sh-taxijob:server:requestDailyMissions', function()
    local src = source
    local cid = NM_GetCid(src)
    if not cid then return end
    GetPlayerLevel(cid, function(level)
        GetOrCreateDailyTimer(cid, function(msToReset, isNew)
            if isNew then
                -- Ciclo nuevo: generar lista fresca y guardarla
                local missions = GenerateMissionList(level)
                local resetAt  = os.time() * 1000 + msToReset
                SaveMissionsForPlayer(cid, missions, resetAt)
                local visible = {}
                for _, m in ipairs(missions) do
                    local gradeCfg = Config.MissionGrades[m.gradeKey]
                    if gradeCfg and level >= gradeCfg.levelRequired then
                        table.insert(visible, m)
                        if #visible >= (Config.DailyMissionMaxVisible or 10) then break end
                    end
                end
                playerMissionCache[cid] = { missions=visible, generatedAt=os.time() }
                TriggerClientEvent('sh-taxijob:client:receiveDailyMissions', src, {
                    missions=visible, msToReset=msToReset, playerLevel=level })
                TriggerClientEvent('sh-taxijob:client:updateDailyTimer', src, msToReset)
            else
                -- Ciclo existente: cargar solo las pendientes de la DB
                MySQL.query(
                    'SELECT `mission_idx`,`grade_key`,`status` FROM `sh_taxijob_daily_missions` WHERE `citizenid`=? AND `reset_at`>? ORDER BY `mission_idx` ASC',
                    { cid, os.time() * 1000 },
                    function(rows)
                        -- Si no hay nada en DB (ej: primer inicio tras install), generar
                        if not rows or #rows == 0 then
                            local missions = GenerateMissionList(level)
                            local resetAt  = os.time() * 1000 + msToReset
                            SaveMissionsForPlayer(cid, missions, resetAt)
                            local visible = {}
                            for _, m in ipairs(missions) do
                                local gradeCfg = Config.MissionGrades[m.gradeKey]
                                if gradeCfg and level >= gradeCfg.levelRequired then
                                    table.insert(visible, m)
                                    if #visible >= (Config.DailyMissionMaxVisible or 10) then break end
                                end
                            end
                            playerMissionCache[cid] = { missions=visible, generatedAt=os.time() }
                            TriggerClientEvent('sh-taxijob:client:receiveDailyMissions', src, {
                                missions=visible, msToReset=msToReset, playerLevel=level })
                            TriggerClientEvent('sh-taxijob:client:updateDailyTimer', src, msToReset)
                            return
                        end

                        -- Reconstruir cada misión pendiente con datos CORRECTOS del grado guardado en DB
                        local visible = {}
                        for _, r in ipairs(rows) do
                            if r.status == 'pending' then
                                local gk      = r.grade_key
                                local gradeCfg = Config.MissionGrades[gk]
                                if gradeCfg and level >= (gradeCfg.levelRequired or 0) then
                                    local points = Config.MissionPoints[gk]
                                    if points and #points > 0 then
                                        local pt   = points[math.random(#points)]
                                        local peds = Config.MissionPeds[gk] or Config.MissionPeds['Basico']
                                        local ped  = peds[math.random(#peds)]
                                        local bp   = math.floor((Config.NpcMissionBasePay or 100)
                                                     * (gradeCfg.baseMultiplier or 1.0)
                                                     * (gradeCfg.payMultiplier  or 1.0))
                                        local xr   = math.floor((Config.NpcMissionBaseXp or 50)
                                                     * (gradeCfg.baseMultiplier or 1.0))
                                        local dist = #(vector3(pt.pickup.x, pt.pickup.y, pt.pickup.z) -
                                                       vector3(pt.dropoff.x, pt.dropoff.y, pt.dropoff.z))
                                        table.insert(visible, {
                                            id             = r.mission_idx,
                                            gradeKey       = gk,
                                            gradeLabel     = gradeCfg.label   or gk,
                                            gradeColor     = gradeCfg.color   or '#9b59b6',
                                            pickupX        = pt.pickup.x,  pickupY = pt.pickup.y,
                                            pickupZ        = pt.pickup.z,  pickupH = pt.pickup.w or 0.0,
                                            dropX          = pt.dropoff.x, dropY   = pt.dropoff.y,
                                            dropZ          = pt.dropoff.z,
                                            pedModel       = ped,
                                            basePay        = bp,
                                            xpReward       = xr,
                                            distMeters     = math.floor(dist),
                                            hasTimer       = gradeCfg.hasTimer       or false,
                                            timerSecs      = gradeCfg.timerSeconds   or 0,
                                            bonusPct       = gradeCfg.bonusPct       or 0,
                                            hasProbRunaway = gradeCfg.hasProbRunaway or false,
                                            runawayChance  = gradeCfg.runawayChance  or 0.0,
                                        })
                                        if #visible >= (Config.DailyMissionMaxVisible or 10) then break end
                                    end
                                end
                            end
                        end

                        playerMissionCache[cid] = { missions=visible, generatedAt=os.time() }
                        TriggerClientEvent('sh-taxijob:client:receiveDailyMissions', src, {
                            missions=visible, msToReset=msToReset, playerLevel=level })
                        TriggerClientEvent('sh-taxijob:client:updateDailyTimer', src, msToReset)
                    end
                )
            end
        end)
    end)
end)

-- ─── Aceptar misión diaria ────────────────────
RegisterNetEvent('sh-taxijob:server:acceptNpcMission', function(missionId)
    local src = source
    local cid = NM_GetCid(src)
    if not cid then return end
    if activeMissions[cid] then
        TriggerClientEvent('sh-taxijob:client:notify', src, { type='error', title='Misión activa', message='Terminá tu misión actual primero.' })
        return
    end
    -- FIX: usar cache en vez de regenerar lista aleatoria
    local cached = playerMissionCache[cid]
    if not cached or not cached.missions then
        TriggerClientEvent('sh-taxijob:client:notify', src, { type='error', title='Sin misiones cargadas', message='Abrí el panel de misiones diarias primero.' })
        return
    end
    local chosen = nil
    for _, m in ipairs(cached.missions) do
        if m.id == missionId then chosen = m; break end
    end
    if not chosen then
        TriggerClientEvent('sh-taxijob:client:notify', src, { type='error', title='Error', message='Misión no encontrada. Reabrí el panel.' })
        return
    end
    GetPlayerLevel(cid, function(level)
        local gradeCfg = Config.MissionGrades[chosen.gradeKey]
        if gradeCfg and level < gradeCfg.levelRequired then
            TriggerClientEvent('sh-taxijob:client:notify', src, { type='error', title='Nivel insuficiente',
                message='Necesitás nivel ' .. gradeCfg.levelRequired .. ' para esta misión.' })
            return
        end
        local now = os.time() * 1000
        activeMissions[cid] = { missionId=missionId, gradeKey=chosen.gradeKey, startTime=now, src=src }
        -- pickupZone y dropZone se resuelven en el CLIENTE con GetStreetNameAtCoord
        -- (los nativos de GTA solo están disponibles en el lado cliente).
        chosen.pickupZone = nil
        chosen.dropZone   = nil
        chosen.missionId  = missionId
        TriggerClientEvent('sh-taxijob:client:startNpcMission', src, chosen)
        TriggerClientEvent('sh-taxijob:client:notify', src, { type='info', title='Misión Aceptada e iniciada', message='Dirigite al punto de recogida.' })
    end)
end)

-- ─── Cancelar misión NPC (iniciada por el jugador) ───
RegisterNetEvent('sh-taxijob:server:cancelNpcMission', function(data)
    local src = source
    local cid = NM_GetCid(src)
    if not cid then return end
    -- Solo liberar el slot activo — la misión queda en 'pending' en la DB
    -- para que siga apareciendo en la lista cuando el jugador vuelva a abrirla.
    activeMissions[cid] = nil
end)

-- ─── Finalizar misión NPC ─────────────────────
RegisterNetEvent('sh-taxijob:server:finishNpcMission', function(data)
    local src = source
    local cid = NM_GetCid(src)
    if not cid then return end
    local active = activeMissions[cid]
    if not active then return end

    local gradeKey        = data.gradeKey or 'Basico'
    local gradeCfg        = Config.MissionGrades[gradeKey] or {}
    local finalPay        = tonumber(data.finalPay)  or 0
    local runaway         = data.runaway    == true
    local timedBonus      = data.timedBonus == true
    local meters          = tonumber(data.meters) or 0
    local isAvanzadoChase = data.isAvanzadoChase == true  -- Avanzado: NPC huyó, persecución pendiente
    local isEspecial      = data.isEspecial      == true  -- Especial: propina fija adicional
    local now             = os.time()
    local nowMs           = now * 1000

    -- Si es Avanzado con persecución pendiente: NO cerramos activeMissions aún,
    -- el pago base va a la empresa, pero la propina queda pendiente del chase.
    -- Si el NPC pagó normalmente (runaway=false) o es otro grado: cerrar misión.
    if not isAvanzadoChase then
        activeMissions[cid] = nil
    end

    MySQL.query(
        'UPDATE `sh_taxijob_daily_missions` SET `status`=?,`finished_at`=?,`final_pay`=?,`runaway`=? WHERE `citizenid`=? AND `mission_idx`=? AND `status`=?',
        { (runaway and not isAvanzadoChase) and 'failed' or 'done', nowMs, finalPay, runaway and 1 or 0, cid, data.missionId, 'pending' })

    if isAvanzadoChase then
        -- Avanzado: NPC huyó sin pagar → el pago base NO se acredita aún,
        -- se espera el resultado de la persecución. Solo registrar en historial
        -- con $0 por ahora (se actualiza si el jugador atrapa al NPC).
        MySQL.insert('INSERT INTO `sh_taxijob_trip_history`(`driver_cid`,`driver_name`,`trip_cost`,`tip`,`meters`,`finished_at`)VALUES(?,?,?,0,?,?)',
            { cid, NM_GetName(src), 0, meters, now })
        -- XP parcial (mitad) porque el NPC huyó, aún puede recuperarlo
        local xpMin    = Config.XpPerTrip and Config.XpPerTrip.min or 50
        local xpMax    = Config.XpPerTrip and Config.XpPerTrip.max or 200
        local xpGained = math.floor(math.random(xpMin, xpMax) * 0.5)
        if gradeCfg.baseMultiplier and gradeCfg.baseMultiplier > 1.0 then
            xpGained = math.floor(xpGained * gradeCfg.baseMultiplier)
        end
        -- Guardar en cache para el evento de chase success/failed
        playerMissionCache[cid .. '_chase'] = {
            missionId=data.missionId, finalPay=finalPay, meters=meters,
            xpParcial=xpGained, timedBonus=timedBonus, gradeKey=gradeKey }
        -- Otorgar XP parcial ya
        MySQL.query('SELECT `xp`,`level` FROM `sh_taxijob_xp` WHERE `citizenid`=?', { cid }, function(xpRow)
            local curXp  = (xpRow and xpRow[1] and xpRow[1].xp)   or 0
            local curLvl = (xpRow and xpRow[1] and xpRow[1].level) or 0
            local newXp  = curXp + xpGained
            local newLvl = curLvl
            for lvl = #Config.Levels, 0, -1 do
                local lvlCfg = Config.Levels[lvl]
                if lvlCfg and newXp >= lvlCfg.xpRequired then newLvl = lvl; break end
            end
            MySQL.query('INSERT INTO `sh_taxijob_xp`(`citizenid`,`xp`,`level`) VALUES(?,?,?) ON DUPLICATE KEY UPDATE `xp`=?,`level`=?',
                { cid, newXp, newLvl, newXp, newLvl })
            if newLvl > curLvl then
                TriggerClientEvent('sh-taxijob:client:notify', src, { type='success', title='¡Subiste de nivel!',
                    message='Nivel ' .. newLvl .. ' — ' .. (Config.Levels[newLvl] and Config.Levels[newLvl].label or '') })
            end
            TriggerClientEvent('sh-taxijob:client:xpUpdate', src, { xp=newXp, level=newLvl, xpGained=xpGained })
        end)
        return  -- Esperar resultado de la persecución
    end

    if runaway then
        TriggerClientEvent('sh-taxijob:client:notify', src, { type='error', title='¡Se escapó!', message='El pasajero huyó sin pagar. Igual ganás XP por el viaje.' })
    else
        if gradeCfg.payToSociety then
            MySQL.query('UPDATE `sh_taxijob_society` SET `balance`=`balance`+? WHERE `id`=1', { finalPay })
            MySQL.insert('INSERT INTO `sh_taxijob_society_log`(`type`,`amount`,`description`,`done_by`,`created_at`)VALUES(?,?,?,?,?)',
                { 'trip', finalPay, 'Misión NPC ' .. gradeKey .. (timedBonus and ' [bonus tiempo]' or ''), NM_GetName(src), now })
            local bonusPct  = gradeCfg.bonusPct or 0
            TriggerClientEvent('sh-taxijob:client:notify', src, { type='success', title='Misión completada',
                message='Empresa recibió $' .. finalPay .. (timedBonus and ' (+' .. bonusPct .. '% bonus)' or '') .. '.' })
        else
            NM_AddMoney(src, finalPay, 'npc-mission-' .. gradeKey)
            local bonusPct  = gradeCfg.bonusPct or 0
            TriggerClientEvent('sh-taxijob:client:notify', src, { type='success', title='¡Misión completada!',
                message='Recibiste $' .. finalPay .. (timedBonus and ' (+' .. bonusPct .. '% bonus tiempo)' or '') .. '.' })
        end

        -- ── ESPECIAL: propina fija al jugador (va directo al jugador, NO al log de empresa) ──
        if isEspecial then
            local tipAmt = tonumber(data.tipAmountFinal) or (gradeCfg.tipAmount or 0)
            if tipAmt > 0 then
                NM_AddMoney(src, tipAmt, 'npc-especial-tip')
                TriggerClientEvent('sh-taxijob:client:notify', src, { type='success', title='¡Propina Especial!',
                    message='Recibiste $' .. tipAmt .. ' de propina por completar la misión Especial.' })
            end
        end
    end

    -- Historial: registrar con propina penalizada si es Especial
    local tipForHistory = (isEspecial and not runaway) and (tonumber(data.tipAmountFinal) or gradeCfg.tipAmount or 0) or 0
    MySQL.insert('INSERT INTO `sh_taxijob_trip_history`(`driver_cid`,`driver_name`,`trip_cost`,`tip`,`meters`,`finished_at`)VALUES(?,?,?,?,?,?)',
        { cid, NM_GetName(src), runaway and 0 or finalPay, tipForHistory, meters, now })

    -- XP siempre se otorga
    local xpMin    = Config.XpPerTrip and Config.XpPerTrip.min or 50
    local xpMax    = Config.XpPerTrip and Config.XpPerTrip.max or 200
    local xpGained = math.random(xpMin, xpMax)
    if runaway then xpGained = math.floor(xpGained * 0.5) end
    if gradeCfg.baseMultiplier and gradeCfg.baseMultiplier > 1.0 then
        xpGained = math.floor(xpGained * gradeCfg.baseMultiplier)
    end
    MySQL.query('SELECT `xp`,`level` FROM `sh_taxijob_xp` WHERE `citizenid`=?', { cid }, function(xpRow)
        local curXp  = (xpRow and xpRow[1] and xpRow[1].xp)    or 0
        local curLvl = (xpRow and xpRow[1] and xpRow[1].level)  or 0
        local newXp  = curXp + xpGained
        local newLvl = curLvl
        for lvl = #Config.Levels, 0, -1 do
            local lvlCfg = Config.Levels[lvl]
            if lvlCfg and newXp >= lvlCfg.xpRequired then newLvl = lvl; break end
        end
        MySQL.query('INSERT INTO `sh_taxijob_xp`(`citizenid`,`xp`,`level`) VALUES(?,?,?) ON DUPLICATE KEY UPDATE `xp`=?,`level`=?',
            { cid, newXp, newLvl, newXp, newLvl })
        if newLvl > curLvl then
            TriggerClientEvent('sh-taxijob:client:notify', src, { type='success', title='¡Subiste de nivel!',
                message='Nivel ' .. newLvl .. ' — ' .. (Config.Levels[newLvl] and Config.Levels[newLvl].label or '') })
        end
        TriggerClientEvent('sh-taxijob:client:xpUpdate', src, { xp=newXp, level=newLvl, xpGained=xpGained })
    end)
end)

-- ─── Avanzado: persecución exitosa (jugador atrapó al NPC) ───
RegisterNetEvent('sh-taxijob:server:advancedChaseSuccess', function(data)
    local src = source
    local cid = NM_GetCid(src)
    if not cid then return end
    activeMissions[cid] = nil

    local cache = playerMissionCache[cid .. '_chase']
    playerMissionCache[cid .. '_chase'] = nil

    local now       = os.time()
    local tipAmount = (data and tonumber(data.tipAmount)) or
                      (Config.MissionGrades['Avanzado'] and Config.MissionGrades['Avanzado'].tipAmount) or 500
    local gradeCfg  = Config.MissionGrades['Avanzado'] or {}
    local basePay   = cache and cache.finalPay or 0
    local meters    = cache and cache.meters   or 0

    -- Pago base a la cuenta bancaria (empresa)
    if basePay > 0 then
        MySQL.query('UPDATE `sh_taxijob_society` SET `balance`=`balance`+? WHERE `id`=1', { basePay })
        MySQL.insert('INSERT INTO `sh_taxijob_society_log`(`type`,`amount`,`description`,`done_by`,`created_at`)VALUES(?,?,?,?,?)',
            { 'trip', basePay, 'Misión Avanzada [pago base recuperado]', NM_GetName(src), now })
    end
    -- Propina va DIRECTO al jugador (no al banco de la empresa)
    NM_AddMoney(src, tipAmount, 'npc-chase-tip')

    -- Actualizar historial con el total real
    MySQL.insert('INSERT INTO `sh_taxijob_trip_history`(`driver_cid`,`driver_name`,`trip_cost`,`tip`,`meters`,`finished_at`)VALUES(?,?,?,?,?,?)',
        { cid, NM_GetName(src), basePay, tipAmount, meters, now })

    TriggerClientEvent('sh-taxijob:client:notify', src, { type='success', title='¡Pago recuperado!',
        message='Banco empresa recibió $' .. basePay .. ' (viaje). Propina de $' .. tipAmount .. ' acreditada en tu cuenta.' })

    -- ── DROP DE ITEMS (probabilidad independiente del pago) ──────
    -- Paso 1: tirar dado para ver si cae ALGO
    local dropCfg = Config.ChaseItemDrop
    if dropCfg and dropCfg.items and #dropCfg.items > 0 then
        if math.random() <= (dropCfg.dropChance or 0.10) then
            -- Paso 2: normalizar chances y elegir item
            local totalChance = 0
            for _, it in ipairs(dropCfg.items) do totalChance = totalChance + (it.chance or 1.0) end
            local roll = math.random() * totalChance
            local cumul = 0.0
            local chosen = dropCfg.items[1]
            for _, it in ipairs(dropCfg.items) do
                cumul = cumul + (it.chance or 1.0)
                if roll <= cumul then chosen = it; break end
            end
            -- Dar el item al jugador
            local itemName   = chosen.item   or 'radio'
            local itemLabel  = chosen.label  or itemName
            local itemAmount = chosen.amount or 1
            local p = NM_GetPlayer(src)
            if p then
                local ok = false
                if Framework_NM == 'qbox' then
                    ok = pcall(function()
                        exports['ox_inventory']:AddItem(src, itemName, itemAmount)
                    end)
                    if not ok then
                        -- Fallback QBX nativo
                        p.Functions.AddItem(itemName, itemAmount)
                        ok = true
                    end
                elseif Framework_NM == 'qbcore' then
                    ok = p.Functions.AddItem(itemName, itemAmount)
                end
                if ok then
                    TriggerClientEvent('sh-taxijob:client:notify', src, { type='info',
                        title='¡Encontraste algo!',
                        message='El civil llevaba: ' .. itemLabel .. ' x' .. itemAmount })
                end
            end
        end
    end

    -- XP adicional (completar la XP que faltaba)
    local xpMin    = Config.XpPerTrip and Config.XpPerTrip.min or 50
    local xpMax    = Config.XpPerTrip and Config.XpPerTrip.max or 200
    local xpExtra  = math.floor(math.random(xpMin, xpMax) * 0.5)  -- la mitad restante
    if gradeCfg.baseMultiplier and gradeCfg.baseMultiplier > 1.0 then
        xpExtra = math.floor(xpExtra * gradeCfg.baseMultiplier)
    end
    MySQL.query('SELECT `xp`,`level` FROM `sh_taxijob_xp` WHERE `citizenid`=?', { cid }, function(xpRow)
        local curXp  = (xpRow and xpRow[1] and xpRow[1].xp)   or 0
        local curLvl = (xpRow and xpRow[1] and xpRow[1].level) or 0
        local newXp  = curXp + xpExtra
        local newLvl = curLvl
        for lvl = #Config.Levels, 0, -1 do
            local lvlCfg = Config.Levels[lvl]
            if lvlCfg and newXp >= lvlCfg.xpRequired then newLvl = lvl; break end
        end
        MySQL.query('INSERT INTO `sh_taxijob_xp`(`citizenid`,`xp`,`level`) VALUES(?,?,?) ON DUPLICATE KEY UPDATE `xp`=?,`level`=?',
            { cid, newXp, newLvl, newXp, newLvl })
        if newLvl > curLvl then
            TriggerClientEvent('sh-taxijob:client:notify', src, { type='success', title='¡Subiste de nivel!',
                message='Nivel ' .. newLvl .. ' — ' .. (Config.Levels[newLvl] and Config.Levels[newLvl].label or '') })
        end
        TriggerClientEvent('sh-taxijob:client:xpUpdate', src, { xp=newXp, level=newLvl, xpGained=xpExtra })
    end)
end)

-- ─── Avanzado: persecución fallida (tiempo expirado) ─────────
RegisterNetEvent('sh-taxijob:server:advancedChaseFailed', function(data)
    local src = source
    local cid = NM_GetCid(src)
    if not cid then return end
    activeMissions[cid] = nil
    playerMissionCache[cid .. '_chase'] = nil
    -- No se acredita dinero: el historial ya tiene $0 del evento finishNpcMission anterior.
    -- XP ya fue otorgado (mitad) en finishNpcMission con isAvanzadoChase=true.
    TriggerClientEvent('sh-taxijob:client:notify', src, { type='error', title='Civil escapó',
        message='No recuperaste el pago. Recibiste XP parcial por el viaje.' })
end)

-- ─── Enviar timer diario al reconectar ───────
AddEventHandler('playerJoining', function()
    local src = source
    Citizen.SetTimeout(5000, function()
        local cid = NM_GetCid(src)
        if not cid then return end
        local now = os.time() * 1000
        MySQL.query('SELECT `reset_at` FROM `sh_taxijob_daily_timer` WHERE `citizenid`=?', { cid }, function(r)
            if r and r[1] then
                TriggerClientEvent('sh-taxijob:client:updateDailyTimer', src, math.max(0, r[1].reset_at - now))
            end
        end)
    end)
end)

-- ─── Limpiar al desconectarse ─────────────────
AddEventHandler('playerDropped', function()
    local src = source
    for cid, m in pairs(activeMissions) do
        if m.src == src then activeMissions[cid] = nil; break end
    end
    -- Limpiar cache expirado (>2 horas)
    for cid, c in pairs(playerMissionCache) do
        if c and (os.time() - (c.generatedAt or 0)) > 7200 then
            playerMissionCache[cid] = nil
        end
    end
end)

-- ─── Enviar zona + marcador al cliente ───────
RegisterNetEvent('sh-taxijob:server:requestDailyZone', function()
    local src = source
    local loc  = Config.Locations.viajes_diarios
    if loc then
        local locData = { x=loc.coords.x, y=loc.coords.y, z=loc.coords.z, heading=loc.heading }
        TriggerClientEvent('sh-taxijob:client:addDailyMissionsZone', src, locData)
        TriggerClientEvent('sh-taxijob:client:injectDailyMarker',    src, locData)
    end
end)

-- ─── Broadcast zona a jugadores ya conectados (arranque recurso) ─
Citizen.CreateThread(function()
    Citizen.Wait(10000)
    local loc = Config.Locations.viajes_diarios
    if not loc then return end
    local locData = { x=loc.coords.x, y=loc.coords.y, z=loc.coords.z, heading=loc.heading }
    for _, src in ipairs(GetPlayers()) do
        src = tonumber(src)
        TriggerClientEvent('sh-taxijob:client:addDailyMissionsZone', src, locData)
        TriggerClientEvent('sh-taxijob:client:injectDailyMarker',    src, locData)
    end
end)

print('^2[sh-taxijob]^0 Servidor v3 + NPC Missions OK.')

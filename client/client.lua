-- =============================================
--   SH-TAXIJOB | Client v5
-- =============================================
local isTabletOpen   = false
local hasAccess      = false
local isOwner        = false
local isOnDuty       = false
local countdownMs    = 60000
local jobLocations   = {}
local targetZones    = {}
local TargetSystem   = 'none'
-- ClothingSystem eliminado: vestuario usa Config.RopaTrabajo directamente
local spawnedVeh     = 0
local vehicleMenuOpen= false

-- Taxista
local myTripId      = nil
local myTripMeters  = 0
local tripThread    = nil
local missionBlip   = 0

-- Civil
local hasTripClient = false
local clientUIOpen  = false
local taxiBlip      = 0           -- blip sobre el taxista, visible al civil
local taxiDriverSId = nil         -- server ID del taxista, guardado en el civil

local markerCfg={markerType=1,colorName='Celeste',r=80,g=180,b=255,a=160,scaleXY=1.5,scaleZ=0.5}

-- NPC Missions state (declarado aquí para estar disponible en el ESC thread)
local dailyMissionsOpen  = false

-- ─── HELPER: nombre de calle legible ─────────
-- Usa los nativos de GTA para obtener el nombre real de calle y cruce,
-- igual a lo que muestra el minimapa. Ejemplo: "Elgin Avenue & Adam's Apple Blvd"
local function GetStreetName(x, y, z)
    local streetHash, crossingHash = GetStreetNameAtCoord(x, y, z)
    local street   = GetStreetNameFromHashKey(streetHash)   or ''
    local crossing = GetStreetNameFromHashKey(crossingHash) or ''
    if crossing ~= '' and crossing ~= street then
        return street .. ' & ' .. crossing
    end
    return street ~= '' and street or GetNameOfZone(x, y, z)
end
local activeMarkers={}
local markerThread=nil

-- ─── AUTO-DETECT ──────────────────────────────
Citizen.CreateThread(function()
    Citizen.Wait(800)
    if Config.Target ~= 'auto' then TargetSystem=Config.Target
    elseif GetResourceState('ox_target')=='started' then TargetSystem='ox_target'
    elseif GetResourceState('qb-target')=='started' then TargetSystem='qb-target' end
    -- Vestuario: se aplica desde Config.RopaTrabajo (sin illenium ni qb-clothing)
    TriggerServerEvent('sh-taxijob:server:checkPermission')
    TriggerServerEvent('sh-taxijob:server:getMarkerConfig')
    TriggerServerEvent('sh-taxijob:server:getAlertasConfig')
end)

-- ─── PERMISOS ─────────────────────────────────
RegisterNetEvent('sh-taxijob:client:receivePermission',function(data)
    hasAccess=data.hasAccess==true; isOwner=data.isOwner==true; isOnDuty=data.onDuty==true
    if data.msToNext then countdownMs=data.msToNext end
    if hasAccess then
        TriggerServerEvent('sh-taxijob:server:getLocations')
        TriggerServerEvent('sh-taxijob:server:getMarkerConfig')
        TriggerServerEvent('sh-taxijob:server:getMyXP')
    else
        hasAccess=false;isOwner=false;isOnDuty=false
        RemoveTargetZones();activeMarkers={}
    end
    SendNUIMessage({action='dutyState',onDuty=isOnDuty,msToNext=countdownMs})
end)

RegisterNetEvent('sh-taxijob:client:dutyState',function(s)
    isOnDuty=s==true
    if isOnDuty then UpdateTargetZones() else RemoveTargetZones() end
    SendNUIMessage({action='dutyState',onDuty=isOnDuty,msToNext=countdownMs})
end)
RegisterNetEvent('sh-taxijob:client:updateNextPay',function(ms)
    countdownMs=ms; SendNUIMessage({action='updateNextPay',ms=ms})
end)
RegisterNetEvent('sh-taxijob:client:serviceLogEntry',function(entry)
    SendNUIMessage({action='serviceLogEntry',entry=entry})
end)
RegisterNetEvent('sh-taxijob:client:receiveServiceLogs',function(logs)
    SendNUIMessage({action='receiveServiceLogs',logs=logs})
end)
RegisterNetEvent('sh-taxijob:client:receiveTripHistory',function(trips)
    SendNUIMessage({action='receiveTripHistory',trips=trips})
end)
RegisterNetEvent('sh-taxijob:client:receiveSocietyData',function(data)
    SendNUIMessage({action='receiveSocietyData',balance=data.balance,logs=data.logs})
end)

Citizen.CreateThread(function()
    while true do
        Citizen.Wait(1000)
        if isOnDuty and countdownMs>0 then
            countdownMs=countdownMs-1000
            if countdownMs<0 then countdownMs=0 end
            SendNUIMessage({action='tickCountdown',ms=countdownMs})
        end
    end
end)

-- ─── NOTIFY ───────────────────────────────────
RegisterNetEvent('sh-taxijob:client:notify',function(data)
    SendNUIMessage({action='showNotify',type=data.type or 'info',
        title=data.title or '',message=data.message or '',duration=data.duration or Config.NotifyDuration})
end)
local function Notify(t,title,msg)
    SendNUIMessage({action='showNotify',type=t,title=title,message=msg,duration=Config.NotifyDuration})
end

-- ─── MARKERS ──────────────────────────────────
RegisterNetEvent('sh-taxijob:client:updateMarker',function(cfg)
    markerCfg=cfg; RebuildMarkers()
end)
local function StartMarkerThread()
    if markerThread then return end
    markerThread=Citizen.CreateThread(function()
        while #activeMarkers>0 do
            Citizen.Wait(0)
            local myPos=GetEntityCoords(PlayerPedId())
            for _,m in ipairs(activeMarkers) do
                local dist=#(myPos-m.coords)
                local drawDist=markerCfg.drawDistance or 6
                if dist<drawDist then
                    DrawMarker(markerCfg.markerType,m.coords.x,m.coords.y,m.coords.z,
                        0,0,0,0,0,0,
                        markerCfg.scaleXY,markerCfg.scaleXY,markerCfg.scaleZ,
                        markerCfg.r,markerCfg.g,markerCfg.b,markerCfg.a,
                        false,true,2,false,nil,nil,false)
                    if dist<2.5 then
                        local labels={stash='Almacén Taxi',clothing='Vestuario Taxi',
                                      spawn='Garage Taxi',spawnpoint='Salida Vehículo',viajes_diarios='Viajes Diarios'}
                        local lbl=labels[m.locType] or m.locType
                        SetTextFont(4);SetTextScale(0,0.55);SetTextProportional(1)
                        SetTextOutline();SetTextColour(255,220,0,255)
                        SetTextEntry('STRING');SetTextCentre(true)
                        AddTextComponentString(lbl)
                        SetDrawOrigin(m.coords.x,m.coords.y,m.coords.z+1.2,0)
                        DrawText(0,0);ClearDrawOrigin()
                    end
                end
            end
        end
        markerThread=nil
    end)
end
function RebuildMarkers()
    activeMarkers={}
    if not hasAccess then return end
    for _,lt in ipairs({'stash','clothing','spawn','spawnpoint','viajes_diarios'}) do
        if jobLocations[lt] then
            table.insert(activeMarkers,{locType=lt,
                coords=vector3(jobLocations[lt].x,jobLocations[lt].y,jobLocations[lt].z)})
        end
    end
    if #activeMarkers>0 then StartMarkerThread() end
end

RegisterNetEvent('sh-taxijob:client:receiveAlertasConfig', function(cfg)
    -- Reenviar al NUI para que actualice las posiciones en pantalla
    SendNUIMessage({ action = 'receiveAlertasConfig', tripNotifyPos = cfg.tripNotifyPos,
        tripNotifyDur = cfg.tripNotifyDur, clientUiPos = cfg.clientUiPos,
        npcTripUiPos  = cfg.npcTripUiPos or 'bottom-left' })
end)


-- ─── BLIP DE MISIÓN (taxista) — fijo en coord ─
local function SetMissionBlip(x,y,z,label)
    if DoesBlipExist(missionBlip) then RemoveBlip(missionBlip) end
    missionBlip=AddBlipForCoord(x,y,z)
    SetBlipSprite(missionBlip,1)
    SetBlipColour(missionBlip,5)
    SetBlipScale(missionBlip,1.2)
    SetBlipAsShortRange(missionBlip,false)
    SetBlipRoute(missionBlip,true)
    SetBlipRouteColour(missionBlip,5)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentString(label or 'Objetivo Taxi')
    EndTextCommandSetBlipName(missionBlip)
end
local function ClearMissionBlip()
    if DoesBlipExist(missionBlip) then RemoveBlip(missionBlip) end
    missionBlip=0
end

-- ─── BLIP DEL TAXISTA (solo lo ve el civil) ───
-- taxiDriverSId se guarda en el cliente del CIVIL cuando acepta el taxista
-- El thread recrea el blip sobre el PED del taxista en tiempo real

Citizen.CreateThread(function()
    while true do
        Citizen.Wait(500)
        if taxiDriverSId then
            local localPlayerId=GetPlayerFromServerId(taxiDriverSId)
            if localPlayerId ~= 255 then
                local driverPed=GetPlayerPed(localPlayerId)
                if driverPed and driverPed~=0 and DoesEntityExist(driverPed) then
                    if not DoesBlipExist(taxiBlip) then
                        -- Crear blip sobre el jugador taxista (no sobre un vehículo)
                        taxiBlip=AddBlipForEntity(driverPed)
                        SetBlipSprite(taxiBlip,198)   -- sprite taxi amarillo
                        SetBlipColour(taxiBlip,5)
                        SetBlipScale(taxiBlip,0.9)
                        SetBlipAsShortRange(taxiBlip,false)
                        BeginTextCommandSetBlipName('STRING')
                        AddTextComponentString('Tu Taxi')
                        EndTextCommandSetBlipName(taxiBlip)
                    end
                end
            end
        end
    end
end)

local function ClearTaxiBlip()
    if DoesBlipExist(taxiBlip) then RemoveBlip(taxiBlip) end
    taxiBlip=0; taxiDriverSId=nil
end

-- ─── VESTUARIO DE TRABAJO ────────────────────
-- ropaCivil guarda la apariencia del jugador ANTES de ponerse el uniforme.
-- Se llena la primera vez que se usa AplicarRopaTaxi() y se limpia al restaurar.
local ropaCivil = nil

local function AplicarRopaTaxi()
    if not Config.RopaTrabajo then
        Notify('error', 'Sin config', 'Config.RopaTrabajo no está definido.')
        return
    end
    local ped    = PlayerPedId()
    local model  = GetEntityModel(ped)
    local genero = (model == GetHashKey('mp_m_freemode_01')) and 'male' or 'female'
    local ropa   = Config.RopaTrabajo[genero]
    if not ropa then
        Notify('error', 'Sin ropa', 'No hay configuración de ropa para tu género.')
        return
    end

    -- Guardar ropa civil solo una vez (antes de aplicar el uniforme)
    if not ropaCivil then
        ropaCivil = { components = {}, props = {} }
        for i = 0, 11 do
            ropaCivil.components[i] = {
                drawable = GetPedDrawableVariation(ped, i),
                texture  = GetPedTextureVariation(ped, i),
            }
        end
        for i = 0, 7 do
            ropaCivil.props[i] = {
                drawable = GetPedPropIndex(ped, i),
                texture  = GetPedPropTextureIndex(ped, i),
            }
        end
    end

    -- Animación de cambio
    local dict = 'clothingtrousers'
    RequestAnimDict(dict)
    local tw = 0
    while not HasAnimDictLoaded(dict) do
        Citizen.Wait(50); tw = tw + 50
        if tw > 3000 then break end
    end
    TaskPlayAnim(ped, dict, 'try_trousers_positive_b', 3.0, -1, -1, 49, 0, 0, 0, 0)

    -- Aplicar prendas del config
    for _, v in pairs(ropa) do
        if v.component then
            SetPedComponentVariation(ped, v.component, v.drawable, v.texture, 0)
        elseif v.prop ~= nil then
            if v.drawable == -1 then
                ClearPedProp(ped, v.prop)
            else
                SetPedPropIndex(ped, v.prop, v.drawable, v.texture, true)
            end
        end
    end

    Citizen.Wait(2500)
    ClearPedTasks(ped)
    Notify('success', 'Vestuario', 'Uniforme de taxi puesto correctamente.')
end

local function RestaurarRopaCivil()
    if not ropaCivil then
        Notify('info', 'Ropa Civil', 'No hay ropa civil guardada para restaurar.')
        return
    end
    local ped = PlayerPedId()

    -- Animación de cambio
    local dict = 'clothingtrousers'
    RequestAnimDict(dict)
    local tw = 0
    while not HasAnimDictLoaded(dict) do
        Citizen.Wait(50); tw = tw + 50
        if tw > 3000 then break end
    end
    TaskPlayAnim(ped, dict, 'try_trousers_positive_b', 3.0, -1, -1, 49, 0, 0, 0, 0)

    -- Restaurar components
    for i, v in pairs(ropaCivil.components) do
        SetPedComponentVariation(ped, i, v.drawable, v.texture, 0)
    end
    -- Restaurar props
    for i, v in pairs(ropaCivil.props) do
        if v.drawable == -1 then
            ClearPedProp(ped, i)
        else
            SetPedPropIndex(ped, i, v.drawable, v.texture, true)
        end
    end

    Citizen.Wait(2500)
    ClearPedTasks(ped)
    ropaCivil = nil   -- limpiar para que la próxima vez vuelva a guardar
    Notify('success', 'Ropa Civil', 'Volviste a tu ropa civil.')
end

-- ─── COMANDO /taxiropa ────────────────────────
-- Solo disponible estando de servicio en taxijob.
RegisterCommand('taxiropa', function()
    if not hasAccess then
        Notify('error', 'Sin acceso', 'Necesitás tener el trabajo de taxi.')
        return
    end
    if not isOnDuty then
        Notify('error', 'Sin servicio', 'Iniciá el servicio para usar el uniforme.')
        return
    end
    AplicarRopaTaxi()
end, false)

-- ─── COMANDO /taxijob ─────────────────────────
RegisterCommand('taxijob',function()
    if not hasAccess then
        TriggerServerEvent('sh-taxijob:server:checkPermission')
        Citizen.SetTimeout(600,function()
            if not hasAccess then Notify('error','Sin Acceso','Pedile permiso a un admin.')
            else OpenTablet() end
        end)
        return
    end
    if isTabletOpen then
        SendNUIMessage({action='closeTablet'});SetNuiFocus(false,false);isTabletOpen=false;return
    end
    OpenTablet()
end,false)

function OpenTablet()
    isTabletOpen=true;SetNuiFocus(true,true)
    SendNUIMessage({action='openTablet',isOwner=isOwner,onDuty=isOnDuty,msToNext=countdownMs})
    TriggerServerEvent('sh-taxijob:server:getTabletData')
    TriggerServerEvent('sh-taxijob:server:getCompanyName')
end

-- ─── DATOS ────────────────────────────────────
RegisterNetEvent('sh-taxijob:client:refreshTablet',function()
    if isTabletOpen then TriggerServerEvent('sh-taxijob:server:getTabletData') end
end)
RegisterNetEvent('sh-taxijob:client:receiveTabletData',function(data)
    if data.msToNext and not isOnDuty then countdownMs=data.msToNext end
    SendNUIMessage({action='updateTabletData',data=data})
end)
RegisterNetEvent('sh-taxijob:client:vehiclePurchased',function(model)
    SendNUIMessage({action='vehiclePurchased',model=model})
end)
RegisterNetEvent('sh-taxijob:client:receiveLocations',function(locs)
    jobLocations=locs; RebuildMarkers()
    if isOnDuty then UpdateTargetZones() else RemoveTargetZones() end
    -- Siempre registrar la zona de misiones diarias al recibir ubicaciones
    Citizen.SetTimeout(200, function() RegisterDailyMissionsZone() end)
end)
RegisterNetEvent('sh-taxijob:client:updateLocations',function()
    TriggerServerEvent('sh-taxijob:server:getLocations')
end)

-- ─── /calltaxi (civil solicita) ───────────────
RegisterNetEvent('sh-taxijob:client:requestWaypoint',function()
    local wpBlip=GetFirstBlipInfoId(8)  -- waypoint = tipo 8
    if not DoesBlipExist(wpBlip) then
        Notify('error','Sin Destino','Primero marcá un punto en el mapa (destino del viaje).')
        return
    end
    local wpCoords=GetBlipInfoIdCoord(wpBlip)
    local toX,toY,toZ = wpCoords.x,wpCoords.y,wpCoords.z
    local toZone      = GetStreetName(toX,toY,toZ)
    -- Posición ACTUAL del civil (de aquí lo va a buscar el taxista)
    local myCoords    = GetEntityCoords(PlayerPedId())
    local fromX,fromY,fromZ = myCoords.x,myCoords.y,myCoords.z
    local fromZone    = GetStreetName(fromX,fromY,fromZ)
    TriggerServerEvent('sh-taxijob:server:submitWaypoint',toX,toY,toZ,toZone,fromZone,fromX,fromY,fromZ)
end)

-- Taxi creado: civil espera
RegisterNetEvent('sh-taxijob:client:tripCreated',function(data)
    hasTripClient=true
    SendNUIMessage({action='clientTripPending',tripId=data.id,
        basePrice=data.basePrice,tips=data.tips})
    Notify('success','Taxi solicitado','Tu pedido fue enviado. Esperá a que alguien lo acepte.')
end)

-- Taxista aceptó → el civil recibe driverServerId y crea el blip SOBRE ESE JUGADOR
RegisterNetEvent('sh-taxijob:client:taxiAccepted',function(data)
    -- Guardar el server ID del taxista para el thread del blip
    taxiDriverSId = data.driverServerId
    Notify('success','¡Taxi en camino!','Tu taxista ya viene. Buscalo en el mapa.')
    SendNUIMessage({action='clientTripAccepted',
        driverName=data.driverName,basePrice=data.basePrice,
        pricePerUnit=data.pricePerUnit,unitMeters=data.unitMeters,tips=data.tips})
end)

-- Taxista llegó, pide al civil que suba
RegisterNetEvent('sh-taxijob:client:taxiArrived',function()
    Notify('success','¡Tu taxi llegó!','El taxista está esperándote. Subite al vehículo.')
end)

-- Civil subió al vehículo del taxista → mostrar UI de viaje
RegisterNetEvent('sh-taxijob:client:passengerBoarded',function(data)
    ClearTaxiBlip()           -- ya no necesita ver el blip, está a bordo
    clientUIOpen=true
    -- Aplicar config de alertas enviada por el server para que la UI del pasajero
    -- quede posicionada según lo configurado por el taxista en la tablet.
    if data.alertasCfg then
        SendNUIMessage({action='receiveAlertasConfig',
            tripNotifyPos=data.alertasCfg.tripNotifyPos,
            tripNotifyDur=data.alertasCfg.tripNotifyDur,
            clientUiPos=data.alertasCfg.clientUiPos,
            npcTripUiPos=data.alertasCfg.npcTripUiPos})
    end
    SendNUIMessage({action='showClientTripUI',tripId=data.tripId,
        basePrice=data.basePrice,tips=data.tips})
    Notify('info','¡Viaje iniciado!','Estás a bordo. La tarifa empieza a correr.')
end)

-- ─── VIAJE ACEPTADO (taxista) ─────────────────
-- data.clientX/Y/Z = posición del civil cuando llamó al taxi (adónde ir a buscarlo)
-- data.toX/Y/Z     = destino marcado por el civil (adónde llevarlo)
RegisterNetEvent('sh-taxijob:client:tripAccepted',function(data)
    myTripId=data.id; myTripMeters=0

    -- Limpiar waypoint del mapa para no confundir
    SetWaypointOff()

    -- ETAPA 1: blip apunta a donde está el civil (posición cuando llamó al taxi)
    SetMissionBlip(data.clientX, data.clientY, data.clientZ,
        'Recoger pasajero — '..data.fromZone)
    SendNUIMessage({action='driverTripActive',trip=data})
    Notify('success','¡Viaje aceptado!','Ve a buscar al pasajero a '..data.fromZone)

    local destX,destY,destZ = data.toX,data.toY,data.toZ
    local destZone           = data.toZone
    local clientSrc          = data.clientSrc
    local passengerOnBoard   = false
    local destReached        = false
    local arrivedNotified    = false

    if tripThread then tripThread=nil end
    tripThread=Citizen.CreateThread(function()
        local lastPos    = GetEntityCoords(PlayerPedId())
        local accMeters  = 0

        -- ══ ETAPA 1: ir a buscar al civil ══════════════════════════════
        -- El taxista conduce hacia donde está el civil (blip ya puesto).
        -- Aquí solo medimos la distancia entre el taxista y el civil.
        -- NO usamos vehículos como referencia: simplemente distancia entre peds.

        while myTripId and not passengerOnBoard do
            Citizen.Wait(1000)

            -- Resolver el ped del civil (jugador que llamó al taxi)
            local localId   = GetPlayerFromServerId(clientSrc)
            if localId == 255 then
                -- El civil no está en nuestro rango de red todavía — esperar
            else
                local clientPed = GetPlayerPed(localId)
                if clientPed ~= 0 and DoesEntityExist(clientPed) then
                    local taxiPos   = GetEntityCoords(PlayerPedId())   -- posición del TAXISTA
                    local clientPos = GetEntityCoords(clientPed)        -- posición del CIVIL
                    local dist      = #(taxiPos - clientPos)

                    -- Paso 1a: notificar al civil cuando el taxista llega cerca (solo 1 vez)
                    if dist < 6.0 and not arrivedNotified then
                        arrivedNotified = true
                        TriggerServerEvent('sh-taxijob:server:taxiArrived', myTripId)
                        Notify('info','Llegaste al civil','Esperá a que suba al vehículo.')
                    end

                    -- Paso 1b: detectar que el civil SUBIÓ A CUALQUIER VEHÍCULO
                    -- (no importa cuál — si el civil está en un vehículo y está cerca, subió)
                    if arrivedNotified then
                        local clientVeh = GetVehiclePedIsIn(clientPed, false)
                        if clientVeh ~= 0 and DoesEntityExist(clientVeh) then
                            -- Civil está en un vehículo y el taxista está cerca: es la señal
                            if dist < 15.0 then
                                passengerOnBoard = true
                                TriggerServerEvent('sh-taxijob:server:passengerBoarded', myTripId)
                                -- ══ ETAPA 2: ir al destino del civil ══
                                -- Limpiar waypoint violeta del mapa
                                SetWaypointOff()
                                SetMissionBlip(destX, destY, destZ, 'Destino: '..destZone)
                                ClearTaxiBlip()  -- ya no necesita ver el blip del taxi (está adentro)
                                Notify('info','¡Pasajero a bordo!','Llevalo a '..destZone)
                                SendNUIMessage({action='driverStage2', toZone=destZone})
                                lastPos = GetEntityCoords(PlayerPedId())
                            end
                        end
                    end
                end
            end
        end

        -- ══ ETAPA 2: llevar al civil al destino ════════════════════════
        -- Contar metros y notificar llegada al destino.
        while myTripId do
            Citizen.Wait(1000)
            local curPos = GetEntityCoords(PlayerPedId())
            -- Contar metros recorridos
            local moved = #(curPos - lastPos)
            if moved > 1 then
                accMeters = accMeters + math.floor(moved)
                lastPos   = curPos
                myTripMeters = accMeters
                TriggerServerEvent('sh-taxijob:server:updateTripMeters', myTripId, accMeters)
            end
            -- Notificar llegada al destino (sin forzar fin, el taxista finaliza cuando quiera)
            if not destReached then
                if #(curPos - vector3(destX,destY,destZ)) < 15.0 then
                    destReached = true
                    Notify('success','¡Destino alcanzado!','Podés finalizar el viaje cuando quieras.')
                    SendNUIMessage({action='showNotify',type='success',
                        title='¡Destino alcanzado!',
                        message='Finalizá el viaje cuando quieras.',duration=6000})
                end
            end
        end
        ClearMissionBlip()
    end)
end)

-- ─── METROS / PROPINA / CAMBIO DEST ───────────
RegisterNetEvent('sh-taxijob:client:tripMeterUpdate',function(data)
    SendNUIMessage({action='tripMeterUpdate',meters=data.meters,totalCost=data.totalCost})
end)
RegisterNetEvent('sh-taxijob:client:tripTipUpdate',function(amount)
    SendNUIMessage({action='tripTipUpdate',tip=amount})
end)
RegisterNetEvent('sh-taxijob:client:waypointChanged',function(data)
    SetMissionBlip(data.toX,data.toY,data.toZ or 0,'Nuevo destino: '..data.toZone)
    SendNUIMessage({action='waypointChanged',toZone=data.toZone})
    Notify('info','Destino cambiado','El pasajero cambió el destino a '..data.toZone)
end)

-- ─── FIN / CANCELACIÓN ────────────────────────
RegisterNetEvent('sh-taxijob:client:tripFinished',function(data)
    myTripId=nil;myTripMeters=0;tripThread=nil
    ClearMissionBlip()
    SendNUIMessage({action='driverTripFinished',totalEarned=data.totalEarned,xpGained=data.xpGained,tip=data.tip})
    local msg='Viaje completado. Sociedad: $'..(data.tripCost or 0)
    if data.tip and data.tip>0 then msg=msg..' | Propina tuya: $'..data.tip end
    msg=msg..' | '..data.xpGained..' XP'
    Notify('success','¡Viaje completado!',msg)
end)
RegisterNetEvent('sh-taxijob:client:tripFinishedClient',function(data)
    hasTripClient=false; clientUIOpen=false
    ClearTaxiBlip()
    SendNUIMessage({action='clientTripFinished',totalCost=data.totalCost,tip=data.tip})
    Notify('info','Viaje completado','Se te cobró $'..data.totalCost..'.')
end)
RegisterNetEvent('sh-taxijob:client:tripCancelledDriver',function()
    hasTripClient=false; clientUIOpen=false
    ClearTaxiBlip()
    SendNUIMessage({action='clientTripCancelled'})
end)
RegisterNetEvent('sh-taxijob:client:driverTripCancelled',function()
    myTripId=nil;myTripMeters=0;tripThread=nil
    ClearMissionBlip()
    SendNUIMessage({action='driverTripFinished',totalEarned=0,xpGained=0,tip=0})
end)
RegisterNetEvent('sh-taxijob:client:newTripRequest',function(dispatch)
    SendNUIMessage({action='newTripRequest',trip=dispatch})
    SendNUIMessage({action='showTripNotify',trip=dispatch})
end)
RegisterNetEvent('sh-taxijob:client:tripTaken',function(tripId)
    SendNUIMessage({action='tripTaken',tripId=tripId})
end)
RegisterNetEvent('sh-taxijob:client:tripRemoved',function(tripId)
    SendNUIMessage({action='tripRemoved',tripId=tripId})
end)

-- ─── SPAWN ────────────────────────────────────
-- ─── SPAWN / DESPAWN ─────────────────────────

-- Función para aplicar customizaciones estéticas a un vehículo
local function ApplyVehicleMods(veh, modConfig)
    if not veh or not DoesEntityExist(veh) then return end
    
    SetVehicleModKit(veh, 0)
    
    -- Aplicar colores
    if modConfig.color then
        SetVehicleColours(veh, modConfig.color[1], modConfig.color[2])
    end
    
    -- Aplicar color de rin
    if modConfig.rimColor then
        local pearl, wheelColor = GetVehicleExtraColours(veh)
        SetVehicleExtraColours(veh, pearl, modConfig.rimColor)
    end
    
    -- Aplicar livery (modtype 48)
    if modConfig.livery then
        SetVehicleLivery(veh, modConfig.livery)
    end
    
    -- Aplicar ruedas (mod type 23)
    if modConfig.wheels then
        SetVehicleWheelType(veh, modConfig.wheels.type)
        SetVehicleMod(veh, 23, modConfig.wheels.index, false)
    end
    
    -- Aplicar mods estéticos (spoiler, parachoques, etc)
    if modConfig.mods then
        for modType, modIndex in pairs(modConfig.mods) do
            SetVehicleMod(veh, modType, modIndex, false)
        end
    end
    
    -- Aplicar extras (spoiler adicional, parachoques, etc)
    if modConfig.extras then
        for extraId, state in pairs(modConfig.extras) do
            SetVehicleExtra(veh, extraId, state and 0 or 1)
        end
    end
end

RegisterNetEvent('sh-taxijob:client:doSpawnVehicle',function(model)
    local spawnLoc=jobLocations.spawnpoint or jobLocations.spawn
    local coords=spawnLoc and vector3(spawnLoc.x,spawnLoc.y,spawnLoc.z) or GetEntityCoords(PlayerPedId())
    local heading=spawnLoc and spawnLoc.heading or GetEntityHeading(PlayerPedId())
    local hash=GetHashKey(model)
    RequestModel(hash)
    local t=0
    while not HasModelLoaded(hash) do
        Citizen.Wait(100);t=t+100
        if t>5000 then Notify('error','Error','No se cargó '..model);return end
    end
    local veh=CreateVehicle(hash,coords.x,coords.y,coords.z,heading,true,false)
    SetVehicleOnGroundProperly(veh)
    SetEntityAsMissionEntity(veh,true,true)
    SetPedIntoVehicle(PlayerPedId(),veh,-1)
    NetworkRequestControlOfEntity(veh)
    Citizen.Wait(200)
    
    -- Aplicar customizaciones estéticas si existen en config
    if Config.VehicleMods and Config.VehicleMods[model] then
        ApplyVehicleMods(veh, Config.VehicleMods[model])
    end
    
    if GetResourceState('qb-vehiclekeys')=='started' then
        TriggerEvent('vehiclekeys:client:SetOwner',GetVehicleNumberPlateText(veh))
    elseif GetResourceState('qs-vehiclekeys')=='started' then
        exports['qs-vehiclekeys']:GiveKeys(veh)
    end
    spawnedVeh=veh
    TriggerServerEvent('sh-taxijob:server:registerVehicle',NetworkGetNetworkIdFromEntity(veh))
    SetModelAsNoLongerNeeded(hash)
    Notify('success','¡Taxi listo!','Vehículo spawneado. ¡Buen turno!')
end)
RegisterNetEvent('sh-taxijob:client:deleteVehicle',function(netId)
    local veh=NetworkDoesNetworkIdExist(netId) and NetToVeh(netId) or 0
    if DoesEntityExist(veh) then DeleteVehicle(veh) end
    if DoesEntityExist(spawnedVeh) then DeleteVehicle(spawnedVeh) end
    spawnedVeh=0
    Notify('info','Vehículo guardado','El taxi fue guardado correctamente.')
end)

-- ─── NUI CALLBACKS ────────────────────────────
RegisterNUICallback('closeTablet',function(_,cb) isTabletOpen=false;SetNuiFocus(false,false);cb('ok') end)
RegisterNUICallback('getTabletData',function(_,cb) TriggerServerEvent('sh-taxijob:server:getTabletData');cb('ok') end)
RegisterNUICallback('toggleDuty',function(_,cb) TriggerServerEvent('sh-taxijob:server:toggleDuty');cb('ok') end)
RegisterNUICallback('updateSalary',function(d,cb) TriggerServerEvent('sh-taxijob:server:updateSalary',d.grade,d.amount);cb('ok') end)
RegisterNUICallback('updateSalaryInterval',function(d,cb) TriggerServerEvent('sh-taxijob:server:updateSalaryInterval',d.interval);cb('ok') end)
RegisterNUICallback('updateMarkerConfig',function(d,cb) markerCfg=d;TriggerServerEvent('sh-taxijob:server:updateMarkerConfig',d);RebuildMarkers();cb('ok') end)
RegisterNUICallback('inviteById',function(d,cb) TriggerServerEvent('sh-taxijob:server:inviteById',d.targetId,d.grade);cb('ok') end)
RegisterNUICallback('inviteNearby',function(d,cb) TriggerServerEvent('sh-taxijob:server:inviteNearby',d.grade);cb('ok') end)
RegisterNUICallback('changeGrade',function(d,cb) TriggerServerEvent('sh-taxijob:server:changeGrade',d.targetId,d.newGrade);cb('ok') end)
RegisterNUICallback('fireEmployee',function(d,cb) TriggerServerEvent('sh-taxijob:server:fireEmployee',d.targetId);cb('ok') end)
RegisterNUICallback('setLocationHere',function(d,cb)
    local c=GetEntityCoords(PlayerPedId());local h=GetEntityHeading(PlayerPedId())
    TriggerServerEvent('sh-taxijob:server:updateLocation',d.locType,c.x,c.y,c.z,h);cb('ok')
end)
RegisterNUICallback('setLocationManual',function(d,cb)
    TriggerServerEvent('sh-taxijob:server:updateLocation',d.locType,d.x,d.y,d.z,d.heading or 0);cb('ok')
end)
RegisterNUICallback('openStash',function(_,cb)
    isTabletOpen=false;SetNuiFocus(false,false);SendNUIMessage({action='closeTablet'})
    TriggerServerEvent('sh-taxijob:server:openStash');cb('ok')
end)
RegisterNUICallback('openClothing',function(_,cb)
    isTabletOpen=false;SetNuiFocus(false,false);SendNUIMessage({action='closeTablet'})
    Citizen.SetTimeout(300, function() AplicarRopaTaxi() end)
    cb('ok')
end)
RegisterNUICallback('spawnVehicle',function(d,cb)
    TriggerServerEvent('sh-taxijob:server:spawnVehicle',d.model)
    isTabletOpen=false;SetNuiFocus(false,false);SendNUIMessage({action='closeTablet'});cb('ok')
end)
RegisterNUICallback('despawnVehicle',function(_,cb) TriggerServerEvent('sh-taxijob:server:despawnVehicle');cb('ok') end)
RegisterNUICallback('buyVehicle',function(d,cb) TriggerServerEvent('sh-taxijob:server:buyVehicle',d.model);cb('ok') end)
RegisterNUICallback('closeVehicleMenu',function(_,cb) vehicleMenuOpen=false;SetNuiFocus(false,false);cb('ok') end)
RegisterNUICallback('closeClientUI',function(_,cb) clientUIOpen=false;cb('ok') end)
RegisterNUICallback('storeCurrentVehicle',function(_,cb)
    local veh=GetVehiclePedIsIn(PlayerPedId(),false)
    if DoesEntityExist(veh) and veh~=0 then
        if DoesEntityExist(spawnedVeh) then DeleteVehicle(spawnedVeh) end
        DeleteVehicle(veh);spawnedVeh=0
        TriggerServerEvent('sh-taxijob:server:despawnVehicle')
    else Notify('error','Sin vehículo','No estás en ningún vehículo.') end
    vehicleMenuOpen=false;SetNuiFocus(false,false);cb('ok')
end)
RegisterNUICallback('acceptTrip',function(d,cb) TriggerServerEvent('sh-taxijob:server:acceptTrip',d.tripId);cb('ok') end)
RegisterNUICallback('cancelTrip',function(d,cb) TriggerServerEvent('sh-taxijob:server:cancelTrip',d.tripId);cb('ok') end)
RegisterNUICallback('finishTrip',function(d,cb) TriggerServerEvent('sh-taxijob:server:finishTrip',d.tripId);cb('ok') end)
RegisterNUICallback('leaveTip',function(d,cb) TriggerServerEvent('sh-taxijob:server:leaveTip',d.amount);cb('ok') end)
RegisterNUICallback('changeWaypoint',function(_,cb)
    local wpBlip=GetFirstBlipInfoId(8)
    if not DoesBlipExist(wpBlip) then Notify('error','Sin destino','Marcá un punto en el mapa primero.');cb('ok');return end
    local wpCoords=GetBlipInfoIdCoord(wpBlip)
    local toZone=GetStreetName(wpCoords.x,wpCoords.y,wpCoords.z)
    TriggerServerEvent('sh-taxijob:server:changeWaypoint',wpCoords.x,wpCoords.y,wpCoords.z,toZone);cb('ok')
end)
RegisterNUICallback('getServiceLogs',function(_,cb) TriggerServerEvent('sh-taxijob:server:getServiceLogs');cb('ok') end)
RegisterNUICallback('getSocietyData',function(_,cb) TriggerServerEvent('sh-taxijob:server:getSocietyData');cb('ok') end)
RegisterNUICallback('societyDeposit',function(d,cb) TriggerServerEvent('sh-taxijob:server:societyDeposit',d.amount);cb('ok') end)
RegisterNUICallback('societyWithdraw',function(d,cb) TriggerServerEvent('sh-taxijob:server:societyWithdraw',d.amount);cb('ok') end)
RegisterNUICallback('societyBonus',function(d,cb) TriggerServerEvent('sh-taxijob:server:societyBonus',d.targetId,d.amount);cb('ok') end)
RegisterNUICallback('getTripHistory',function(_,cb) TriggerServerEvent('sh-taxijob:server:getTripHistory');cb('ok') end)
RegisterNUICallback('clearTripHistory',function(_,cb) TriggerServerEvent('sh-taxijob:server:clearTripHistory');cb('ok') end)
RegisterNUICallback('getOfflineNames',function(d,cb) cb('ok') end)
RegisterNUICallback('getMyXP',function(_,cb) TriggerServerEvent('sh-taxijob:server:getMyXP');cb('ok') end)
RegisterNUICallback('updateTripConfig',function(d,cb) TriggerServerEvent('sh-taxijob:server:updateTripConfig',d);cb('ok') end)
RegisterNUICallback('updatePermission',function(d,cb) TriggerServerEvent('sh-taxijob:server:updatePermission',d.grade,d.panel,d.allowed);cb('ok') end)

-- Recibir actualización de permisos en tiempo real (broadcast del server cuando cualquier owner cambia un permiso)
RegisterNetEvent('sh-taxijob:client:permissionsUpdated',function(updatedPerms)
    SendNUIMessage({action='permissionsUpdated',permissions=updatedPerms})
end)

-- Nombre empresa
RegisterNUICallback('setCompanyName',function(d,cb) TriggerServerEvent('sh-taxijob:server:setCompanyName',d.name);cb('ok') end)

-- Notas
RegisterNUICallback('getNotes',function(_,cb) TriggerServerEvent('sh-taxijob:server:getNotes');cb('ok') end)
RegisterNUICallback('saveNote',function(d,cb) TriggerServerEvent('sh-taxijob:server:saveNote',d.note);cb('ok') end)
RegisterNUICallback('deleteNote',function(d,cb) TriggerServerEvent('sh-taxijob:server:deleteNote',d and d.targetCid or nil);cb('ok') end)
RegisterNUICallback('placeBoardNote',function(d,cb)
    local pos=GetEntityCoords(PlayerPedId())
    local height = Config.BoardNoteHeight or 1.0
    TriggerServerEvent('sh-taxijob:server:placeBoardNote',d.note,pos.x,pos.y,pos.z+height)
    cb('ok')
end)
RegisterNUICallback('removeBoardNote',function(_,cb) TriggerServerEvent('sh-taxijob:server:removeBoardNote');cb('ok') end)
-- Fallback legacy: en versiones antiguas de qb-inventory el open era client-side.
-- Con qb-inventory moderno el servidor llama OpenInventory directamente y este
-- evento nunca se dispara. Se mantiene por si hay algún fork que lo necesite.
RegisterNetEvent('sh-taxijob:client:openQbStash',function(stashName)
    if GetResourceState('qb-inventory')=='started' then
        TriggerEvent('qb-inventory:client:openInventory', stashName)
    end
end)

-- ─── VEHICLE MENU ─────────────────────────────
local playerLevel = 0  -- nivel XP del taxista

RegisterNetEvent('sh-taxijob:client:xpUpdate',function(data)
    if data and data.level then playerLevel=data.level end
end)

local vehiclePurchaseCache={}

local function OpenVehicleMenu()
    if not hasAccess then return end
    if not isOnDuty then Notify('error','Sin Servicio','Iniciá el servicio primero.');return end
    
    -- Solicitar datos de compra actualizados
    TriggerServerEvent('sh-taxijob:server:requestVehiclePurchases')
    Wait(100)
    
    vehicleMenuOpen=true;SetNuiFocus(true,true)
    SendNUIMessage({action='openVehicleMenu',vehicles=Config.SpawnVehicles,
        vehiclePurchases=vehiclePurchaseCache,hasCar=DoesEntityExist(spawnedVeh),playerLevel=playerLevel,purchaseData=vehiclePurchaseCache,onDuty=isOnDuty})
end

RegisterNetEvent('sh-taxijob:client:updateVehiclePurchases',function(purchaseData)
    vehiclePurchaseCache=purchaseData or {}
    -- Enviar actualización al frontend para que re-renderice en tiempo real
    SendNUIMessage({action='updateVehiclePurchases',purchases=vehiclePurchaseCache})
end)

-- ─── TARGET ZONES ─────────────────────────────
-- ox_target usa `onSelect`, qb-target usa `action`.
-- Esta función normaliza las opciones según el sistema activo
-- para que ambos frameworks funcionen sin tocar la lógica de cada zona.
local function NormalizeOpts(opts)
    if TargetSystem ~= 'ox_target' then return opts end
    local out = {}
    for _, o in ipairs(opts) do
        local opt = {}
        for k, v in pairs(o) do opt[k] = v end
        if opt.action and not opt.onSelect then
            opt.onSelect = opt.action
            opt.action   = nil
        end
        table.insert(out, opt)
    end
    return out
end

-- Zonas que requieren estar en servicio (stash, clothing, spawn)
function UpdateTargetZones()
    RemoveTargetZones()
    if not hasAccess or not isOnDuty then
        -- Aunque no esté en servicio, siempre registrar la zona de misiones diarias
        RegisterDailyMissionsZone()
        return
    end
    local dist=Config.TargetDistance
    local function addZone(name,coords,opts)
        local finalOpts = NormalizeOpts(opts)
        if TargetSystem=='ox_target' then
            exports['ox_target']:addSphereZone({coords=coords,radius=dist,options=finalOpts,name=name})
            table.insert(targetZones,{type='ox',name=name})
        elseif TargetSystem=='qb-target' then
            exports['qb-target']:AddCircleZone(name,coords,dist,
                {name=name,useZ=true,debugPoly=false},{options=finalOpts,distance=dist})
            table.insert(targetZones,{type='qb',name=name})
        end
    end
    if jobLocations.stash then
        addZone('sh_taxijob_stash',vector3(jobLocations.stash.x,jobLocations.stash.y,jobLocations.stash.z),{
            {label='Almacén Taxi',icon='fas fa-box',action=function() TriggerServerEvent('sh-taxijob:server:openStash') end},
        })
    end
    if jobLocations.clothing then
        addZone('sh_taxijob_clothing',vector3(jobLocations.clothing.x,jobLocations.clothing.y,jobLocations.clothing.z),{
            {label='Vestuario Taxi', icon='fas fa-tshirt',  action=function() AplicarRopaTaxi()    end},
            {label='Ropa Civil',     icon='fas fa-user',    action=function() RestaurarRopaCivil() end},
        })
    end
    if jobLocations.spawn then
        addZone('sh_taxijob_spawn',vector3(jobLocations.spawn.x,jobLocations.spawn.y,jobLocations.spawn.z),{
            {label='Spawn Vehículo',icon='fas fa-car',action=function() OpenVehicleMenu() end},
            {label='Guardar Vehículo',icon='fas fa-parking',action=function()
                local veh=GetVehiclePedIsIn(PlayerPedId(),false)
                if DoesEntityExist(veh) and veh~=0 then
                    if DoesEntityExist(spawnedVeh) then DeleteVehicle(spawnedVeh) end
                    DeleteVehicle(veh);spawnedVeh=0
                    TriggerServerEvent('sh-taxijob:server:despawnVehicle')
                    
                else Notify('error','Sin vehículo','No estás en ningún vehículo.') end
            end},
        })
    end
    -- La zona de misiones diarias se maneja aparte (siempre activa con acceso)
    RegisterDailyMissionsZone()
end

-- ─── ZONA MISIONES DIARIAS (independiente del duty) ─────────
-- Se registra cuando el jugador tiene acceso, sin importar si está en servicio.
-- Se persiste entre reinicios del recurso y cambios de duty.
local dailyZoneRegistered = false

function RegisterDailyMissionsZone()
    if not hasAccess then return end
    if not jobLocations.viajes_diarios then return end
    -- Eliminar la zona previa si existe para evitar duplicados
    if dailyZoneRegistered then
        if TargetSystem == 'ox_target' then
            pcall(function() exports['ox_target']:removeZone('sh_taxijob_viajes_diarios') end)
        elseif TargetSystem == 'qb-target' then
            pcall(function() exports['qb-target']:RemoveZone('sh_taxijob_viajes_diarios') end)
        end
        dailyZoneRegistered = false
    end

    local dist   = Config.TargetDistance or 3.0
    local coords = vector3(jobLocations.viajes_diarios.x, jobLocations.viajes_diarios.y, jobLocations.viajes_diarios.z)

    local misionAction = function()
        if not hasAccess then return end
        if not isOnDuty then
            Notify('error','Sin servicio','Iniciá el servicio para ver las misiones.')
            return
        end
        TriggerServerEvent('sh-taxijob:server:requestDailyMissions')
    end

    if TargetSystem == 'ox_target' then
        exports['ox_target']:addSphereZone({
            coords  = coords, radius = dist, name = 'sh_taxijob_viajes_diarios',
            options = {{ label='Misiones Diarias', icon='fas fa-tasks',
                onSelect = misionAction
            }}
        })
        dailyZoneRegistered = true
    elseif TargetSystem == 'qb-target' then
        exports['qb-target']:AddCircleZone('sh_taxijob_viajes_diarios', coords, dist,
            { name='sh_taxijob_viajes_diarios', useZ=true, debugPoly=false },
            { options={{ label='Misiones Diarias', icon='fas fa-tasks',
                action = misionAction
              }}, distance = dist })
        dailyZoneRegistered = true
    end
end
function RemoveTargetZones()
    for _,z in ipairs(targetZones) do
        if z.type=='ox' then exports['ox_target']:removeZone(z.name)
        elseif z.type=='qb' then exports['qb-target']:RemoveZone(z.name) end
    end
    targetZones={}
    -- Reconstruir markers (incluye viajes_diarios) y re-registrar la zona target
    RebuildMarkers()
    Citizen.SetTimeout(100, function() RegisterDailyMissionsZone() end)
end

-- ─── ON LOADED ────────────────────────────────
AddEventHandler('QBCore:Client:OnPlayerLoaded',function()
    Citizen.SetTimeout(1000,function() TriggerServerEvent('sh-taxijob:server:checkPermission') end)
end)
Citizen.CreateThread(function()
    Citizen.Wait(5000); TriggerServerEvent('sh-taxijob:server:checkPermission')
end)

-- ─── HOTKEYS via RegisterKeyMapping ───────────
-- Todas las teclas se definen en Config.Hotkeys
-- No hay panel de accesos rápidos — se configuran desde config.lua

local function RegisterHotkeys()
    -- Slots 1-4: propinas del civil
    -- Slot 5: cambiar destino (civil)
    -- Slot 6: aceptar viaje rápido (taxista)
    -- Slot 7: ignorar alerta de viaje (taxista)
    local slotLabels={
        'Propina 1 (civil)','Propina 2 (civil)','Propina 3 (civil)',
        'Propina 4 (civil)','Cambiar destino (civil)',
        'Aceptar viaje (taxista)','Ignorar alerta (taxista)',
    }
    for slot,key in pairs(Config.Hotkeys) do
        if key ~= '' then
            local cmdName='_shtaxi_slot'..slot
            RegisterKeyMapping(cmdName, slotLabels[slot] or ('Taxi slot '..slot), 'keyboard', key:lower())
            RegisterCommand(cmdName, function()
                if slot <= 5 then
                    -- Civil: solo si tiene viaje activo
                    if hasTripClient then
                        SendNUIMessage({action='hotkey',slot=slot})
                    end
                elseif slot == 6 then
                    -- Taxista: aceptar viaje rápido
                    if isOnDuty and not isTabletOpen then
                        SendNUIMessage({action='acceptLatestTrip'})
                    end
                elseif slot == 7 then
                    -- Taxista: ignorar alerta
                    if isOnDuty then
                        SendNUIMessage({action='dismissLatestTrip'})
                    end
                end
            end, false)
        end
    end
end

-- Registrar teclas al iniciar
AddEventHandler('onClientResourceStart',function(res)
    if res ~= GetCurrentResourceName() then return end
    Citizen.SetTimeout(1000, RegisterHotkeys)
    -- Re-registrar zona de misiones diarias al reiniciar el recurso
    Citizen.SetTimeout(3000, function()
        if hasAccess then
            TriggerServerEvent('sh-taxijob:server:getLocations')
        end
    end)
end)
Citizen.CreateThread(function()
    Citizen.Wait(1500); RegisterHotkeys()
end)

-- ─── ESC ──────────────────────────────────────
Citizen.CreateThread(function()
    while true do
        Citizen.Wait(0)
        if (isTabletOpen or vehicleMenuOpen) and IsControlJustReleased(0,200) then
            SendNUIMessage({action='escapePressed'})
        end
        if dailyMissionsOpen and IsControlJustReleased(0,200) then
            dailyMissionsOpen = false
            SetNuiFocus(false, false)
            SendNUIMessage({action='forceCloseDailyMissions'})
        end
    end
end)

-- ─── BOARD NOTES (DRAWTEXT 3D) ───────────────
local boardNotes = {}   -- cid → {text, x, y, z, name}
local myBoardCid = nil  -- cid del jugador actual (recibido del server)

local boardThread = nil
local function StartBoardThread()
    if boardThread then return end
    boardThread = Citizen.CreateThread(function()
        while true do
            Citizen.Wait(0)
            local hasAny = false
            local myPos = GetEntityCoords(PlayerPedId())
            for cid, n in pairs(boardNotes) do
                hasAny = true
                local dist = #(myPos - vector3(n.x, n.y, n.z))
                if dist < Config.BoardNotes.DrawDistance then
                    -- Draw3DText
                    local camRot = GetGameplayCamRot(2)
                    local scale = 0.35
                    SetTextScale(scale, scale)
                    SetTextFont(4)
                    SetTextProportional(1)
                    SetTextColour(255, 235, 80, 235)
                    SetTextOutline()
                    SetTextEntry('STRING')
                    SetTextCentre(true)
                    local display = '📌 '..n.name..'\n'..n.text
                    AddTextComponentString(display)
                    SetDrawOrigin(n.x, n.y, n.z, 0)
                    DrawText(0.0, 0.0)
                    ClearDrawOrigin()
                end
            end
            if not hasAny then
                boardThread = nil
                return
            end
        end
    end)
end

RegisterNetEvent('sh-taxijob:client:boardNoteAdded', function(cid, note)
    boardNotes[cid] = note
    StartBoardThread()
end)
RegisterNetEvent('sh-taxijob:client:boardNoteRemoved', function(cid)
    boardNotes[cid] = nil
end)
RegisterNetEvent('sh-taxijob:client:receiveBoardNotes', function(notes)
    boardNotes = notes or {}
    for _ in pairs(boardNotes) do StartBoardThread(); break end
end)

-- Recibir nombre de empresa
RegisterNetEvent('sh-taxijob:client:receiveCompanyName', function(name)
    SendNUIMessage({action='receiveCompanyName', name=name})
end)

-- Recibir notas (panel)
RegisterNetEvent('sh-taxijob:client:receiveNotes', function(rows)
    SendNUIMessage({action='receiveNotes', notes=rows})
end)
RegisterNetEvent('sh-taxijob:client:noteUpdated', function(entry)
    SendNUIMessage({action='noteUpdated', entry=entry})
end)
RegisterNetEvent('sh-taxijob:client:noteDeleted', function(cid)
    SendNUIMessage({action='noteDeleted', cid=cid})
end)

-- Al conectar, pedir notas de pizarra activas
Citizen.CreateThread(function()
    Citizen.Wait(3000)
    TriggerServerEvent('sh-taxijob:server:requestBoardNotes')
end)

RegisterNUICallback('updateAlertasConfig', function(data, cb)
    TriggerServerEvent('sh-taxijob:server:updateAlertasConfig', data)
    cb('ok')
end)

RegisterNUICallback('getAlertasConfig', function(_, cb)
    TriggerServerEvent('sh-taxijob:server:getAlertasConfig')
    cb('ok')
end)

-- ─── RADIO ───────────────────────────────────
RegisterNUICallback('getRadioState',function(_,cb) TriggerServerEvent('sh-taxijob:server:getRadioState');cb('ok') end)
RegisterNUICallback('joinRadioChannel',function(d,cb) TriggerServerEvent('sh-taxijob:server:joinRadioChannel',d.slot);cb('ok') end)
RegisterNUICallback('setRadioFreq',function(d,cb) TriggerServerEvent('sh-taxijob:server:setRadioFreq',d.slot,d.freq);cb('ok') end)
RegisterNUICallback('pitarRadio',function(d,cb) TriggerServerEvent('sh-taxijob:server:pitarRadio',d.targetSrc);cb('ok') end)

RegisterNetEvent('sh-taxijob:client:radioState',function(channels)
    SendNUIMessage({action='radioState',channels=channels})
end)
RegisterNetEvent('sh-taxijob:client:radioOnDuty',function(list)
    SendNUIMessage({action='radioOnDuty',list=list})
end)

-- El servidor avisa al cliente en qué frecuencia debe estar en pma-voice
-- freq=0 significa salir de la radio
RegisterNetEvent('sh-taxijob:client:setRadioFreq',function(freq)
    if GetResourceState('pma-voice') ~= 'started' then return end
    local ok, err = pcall(function()
        if freq and freq > 0 then
            -- Patrón exacto del script policial que funciona:
            -- 1. Setear canal
            exports['pma-voice']:setRadioChannel(freq)
            -- 2. Habilitar la radio en pma-voice (sin esto el icono cambia pero no transmite)
            exports['pma-voice']:setVoiceProperty('radioEnabled', true)
        else
            -- Salir: deshabilitar radio y setear canal 0
            exports['pma-voice']:setVoiceProperty('radioEnabled', false)
            exports['pma-voice']:setRadioChannel(0)
        end
    end)
    if not ok and Config.Debug then
        print('[sh-taxijob] pma-voice error: '..(err or '?'))
    end
end)


-- =============================================
--   NPC MISSIONS (fusionado desde client_npcmissions.lua)
-- =============================================

-- ─── Variables de estado NPC ─────────────────
local npcMission         = nil
-- dailyMissionsOpen declarado al inicio del archivo
local npcPed             = 0
local npcBlip            = 0
local npcDropBlip        = 0
local npcMissionThread   = nil
local npcUIActive        = false

local stressLevel        = 0.0
local scaredLevel        = 0.0
local stressLocked       = false
local missionTimerLeft   = 0
local missionTimerThread = nil
local distanceMeter      = 0
local missionCost        = 0
local missionBasePay     = 0

local penaltyScaredApplied = false
local penaltyStressApplied = false

-- Variables exclusivas de misiones Avanzadas (persecución)
local chaseActive        = false   -- true cuando el NPC huyó y hay persecución activa
local chaseTimerLeft     = 0       -- segundos restantes para atrapar al NPC
local chaseTimerThread   = nil     -- thread del countdown de persecución
local chaseBlip          = 0       -- blip rojo sobre el NPC que huye
local chaseNpcPed        = 0       -- referencia al ped huyendo (mismo que npcPed)

-- Variables exclusivas de misiones Especiales (autos hostiles)
local especialCarsActive  = false  -- true durante el viaje Especial con autos hostiles
local especialChaserVehs  = {}     -- lista de vehículos hostiles spawneados
local especialChaserPeds  = {}     -- lista de peds conductores hostiles
local especialChaserBlips = {}     -- lista de blips rojos de los autos perseguidores
local especialWaveThread  = nil    -- thread que controla las waves

local KMH_TO_MS = 1000 / 3600

-- ─── Helper notify NPC ───────────────────────
local function NpcNotify(t, title, msg)
    SendNUIMessage({ action='showNotify', type=t, title=title, message=msg,
        duration=Config.NotifyDuration or 5000 })
end

-- ─── Limpiar estado NPC ──────────────────────
local function CleanNpcMission()
    if npcPed and npcPed ~= 0 and DoesEntityExist(npcPed) then DeleteEntity(npcPed) end
    npcPed = 0
    if DoesBlipExist(npcBlip)     then RemoveBlip(npcBlip)     end
    if DoesBlipExist(npcDropBlip) then RemoveBlip(npcDropBlip) end
    if DoesBlipExist(chaseBlip)   then RemoveBlip(chaseBlip)   end
    npcBlip = 0; npcDropBlip = 0; chaseBlip = 0
    npcMission           = nil
    npcUIActive          = false
    stressLevel          = 0.0
    scaredLevel          = 0.0
    stressLocked         = false
    missionTimerLeft     = 0
    distanceMeter        = 0
    missionCost          = 0
    penaltyScaredApplied = false
    penaltyStressApplied = false
    -- Limpiar estado de persecución (Avanzado)
    chaseActive          = false
    chaseTimerLeft       = 0
    chaseNpcPed          = 0
    -- Limpiar autos hostiles (Especial)
    especialCarsActive = false
    if especialWaveThread then especialWaveThread = nil end
    for _, v in ipairs(especialChaserVehs) do
        if DoesEntityExist(v) then DeleteEntity(v) end
    end
    for _, p in ipairs(especialChaserPeds) do
        if DoesEntityExist(p) then DeleteEntity(p) end
    end
    for _, b in ipairs(especialChaserBlips) do
        if DoesBlipExist(b) then RemoveBlip(b) end
    end
    especialChaserVehs  = {}
    especialChaserPeds  = {}
    especialChaserBlips = {}
    -- Asegurar que el foco NUI quede libre al terminar la misión
    if dailyMissionsOpen then
        dailyMissionsOpen = false
        SetNuiFocus(false, false)
    end
    SendNUIMessage({ action = 'hideNpcMissionUI' })
    SetWaypointOff()
end

-- ─── Blips NPC ───────────────────────────────
local function SetNpcPickupBlip(x, y, z, label)
    if DoesBlipExist(npcBlip) then RemoveBlip(npcBlip) end
    npcBlip = AddBlipForCoord(x, y, z)
    SetBlipSprite(npcBlip, 280); SetBlipColour(npcBlip, 5); SetBlipScale(npcBlip, 1.1)
    SetBlipAsShortRange(npcBlip, false); SetBlipRoute(npcBlip, true); SetBlipRouteColour(npcBlip, 5)
    BeginTextCommandSetBlipName('STRING'); AddTextComponentString(label or 'Recoger NPC'); EndTextCommandSetBlipName(npcBlip)
end

local function SetNpcDropBlip(x, y, z, label)
    if DoesBlipExist(npcDropBlip) then RemoveBlip(npcDropBlip) end
    npcDropBlip = AddBlipForCoord(x, y, z)
    SetBlipSprite(npcDropBlip, 67); SetBlipColour(npcDropBlip, 2); SetBlipScale(npcDropBlip, 1.1)
    SetBlipAsShortRange(npcDropBlip, false); SetBlipRoute(npcDropBlip, true); SetBlipRouteColour(npcDropBlip, 2)
    BeginTextCommandSetBlipName('STRING'); AddTextComponentString(label or 'Dejar NPC'); EndTextCommandSetBlipName(npcDropBlip)
end

-- ─── Spawn NPC ped ───────────────────────────
local function SpawnNpcPed(model, x, y, z, heading, cb)
    local hash = GetHashKey(model)
    RequestModel(hash)
    local t = 0
    while not HasModelLoaded(hash) do
        Citizen.Wait(100); t = t + 100
        if t > 8000 then if cb then cb(nil) end; return end
    end
    local ped = CreatePed(4, hash, x, y, z - 1.0, heading, false, false)
    SetEntityAsMissionEntity(ped, true, true)
    SetPedFleeAttributes(ped, 0, false)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedCanRagdoll(ped, false)
    SetModelAsNoLongerNeeded(hash)
    if cb then cb(ped) end
end

-- ─── Thread barras dinámicas ─────────────────
local barsThread = nil
local function StartBarsThread()
    if barsThread then return end
    barsThread = Citizen.CreateThread(function()
        local lastPos = GetEntityCoords(PlayerPedId())
        while npcUIActive do
            Citizen.Wait(500)
            local veh = GetVehiclePedIsIn(PlayerPedId(), false)
            if DoesEntityExist(veh) and veh ~= 0 then
                local speedKmh = GetEntitySpeed(veh) * 3.6
                local thresh   = Config.StressBars.speedThresholdKmh or 120
                if not stressLocked then
                    if speedKmh >= thresh then
                        stressLevel = math.min(100.0, stressLevel + (Config.StressBars.stressRiseRate or 0.8) * 0.5)
                        if stressLevel >= 100.0 and Config.StressBars.stressMaxLock then
                            stressLevel = 100.0; stressLocked = true
                        end
                    else
                        stressLevel = math.max(0.0, stressLevel - (Config.StressBars.stressFallRate or 0.4) * 0.5)
                    end
                end
                scaredLevel = math.max(0.0, scaredLevel - (Config.StressBars.scaredFallRate or 2.0) * 0.5)
                local curPos = GetEntityCoords(PlayerPedId())
                local moved  = #(curPos - lastPos)
                if moved > 1.0 then
                    distanceMeter = distanceMeter + math.floor(moved)
                    lastPos = curPos
                    -- Usar los valores NPC dedicados (NpcTripUnitMeters / NpcTripPerUnit)
                    -- para no contaminar la economía con los valores de viajes de jugadores.
                    local npcUnit  = Config.NpcTripUnitMeters or 100
                    local npcPer   = Config.NpcTripPerUnit    or 5
                    missionCost = missionBasePay + math.floor(distanceMeter / npcUnit) * npcPer
                end
                SendNUIMessage({ action='npcMissionBarsUpdate', stress=stressLevel, scared=scaredLevel,
                    stressLocked=stressLocked, meters=distanceMeter, cost=missionCost, timerLeft=missionTimerLeft })
            end
        end
        barsThread = nil
    end)
end

-- ─── Detectar impactos en vehículo ───────────
Citizen.CreateThread(function()
    local lastDamage = 0
    while true do
        Citizen.Wait(200)
        if npcUIActive then
            local veh = GetVehiclePedIsIn(PlayerPedId(), false)
            if DoesEntityExist(veh) and veh ~= 0 then
                local damage = GetVehicleEngineHealth(veh)
                if lastDamage == 0 then lastDamage = damage end
                local diff = lastDamage - damage
                if diff > 50 then
                    scaredLevel = math.min(100.0, scaredLevel + (Config.StressBars.scaredRiseRate or 25.0))
                    if scaredLevel >= 100.0 and not penaltyScaredApplied then
                        penaltyScaredApplied = true
                        NpcNotify('error', '¡NPC Asustado!', 'El pasajero está aterrorizado. Recibirás un 25% menos de pago.')
                    end
                end
                lastDamage = damage
            else lastDamage = 0 end
        else lastDamage = 0 end
    end
end)

-- ─── ESPECIAL: spawnear par de autos hostiles ─────────────────────────────
local function SpawnEspecialChaserPair(grade)
    local myPed = PlayerPedId()
    local myPos = GetEntityCoords(myPed)

    local carModels = grade.chaseCarsModels or { 'sultan', 'dominator', 'kuruma' }
    local pedModels = grade.chaserPedModels or { 'g_m_y_lost_01', 'g_m_y_lost_02' }

    -- Calcular la dirección opuesta al heading del jugador (detrás)
    local myHeading = GetEntityHeading(myPed)
    local backRad   = (myHeading + 180.0) * math.pi / 180.0

    for i = 1, 2 do
        -- Spawnear entre 1 y 3 metros detrás del jugador, con pequeño desvío lateral
        local dist     = 1.0 + math.random() * 2.0   -- 1–3 m
        local sideOff  = (i == 1 and -1.5 or 1.5)    -- uno a cada lado
        local spawnX   = myPos.x + math.cos(backRad) * dist + math.cos(backRad + math.pi * 0.5) * sideOff
        local spawnY   = myPos.y + math.sin(backRad) * dist + math.sin(backRad + math.pi * 0.5) * sideOff
        local spawnZ   = myPos.z

        local carModel = carModels[math.random(#carModels)]
        local pedModel = pedModels[math.random(#pedModels)]

        local carHash = GetHashKey(carModel)
        local pedHash = GetHashKey(pedModel)
        RequestModel(carHash); RequestModel(pedHash)
        local tw = 0
        while (not HasModelLoaded(carHash) or not HasModelLoaded(pedHash)) do
            Citizen.Wait(50); tw = tw + 50
            if tw > 4000 then break end
        end

        -- El vehículo mira al jugador (heading inverso al backRad)
        local vehHeading = myHeading
        local veh = CreateVehicle(carHash, spawnX, spawnY, spawnZ, vehHeading, true, false)
        SetEntityAsMissionEntity(veh, true, true)
        SetVehicleEngineOn(veh, true, true, false)

        local ped = CreatePedInsideVehicle(veh, 4, pedHash, -1, true, false)
        SetEntityAsMissionEntity(ped, true, true)
        SetPedAsEnemy(ped, true)
        SetPedCombatAttributes(ped, 52, true)   -- puede usar el auto como arma
        SetPedCombatAttributes(ped, 2,  true)   -- ataca al jugador
        SetPedCombatRange(ped, 2)
        SetBlockingOfNonTemporaryEvents(ped, false)
        -- Dar orden de perseguir y embestir al jugador
        TaskVehicleChase(ped, myPed)
        SetTaskVehicleChaseBehaviorFlag(ped, 0, true)   -- embestir
        SetTaskVehicleChaseBehaviorFlag(ped, 8, true)   -- no rendirse

        SetModelAsNoLongerNeeded(carHash)
        SetModelAsNoLongerNeeded(pedHash)

        -- Blip rojo circular sobre el vehículo perseguidor (círculo = sprite 1 estándar)
        local chaserBlip = AddBlipForEntity(veh)
        SetBlipSprite(chaserBlip, 1)        -- círculo estándar
        SetBlipColour(chaserBlip, 1)        -- 1 = rojo
        SetBlipScale(chaserBlip, 0.85)
        SetBlipAsShortRange(chaserBlip, false)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentString('Perseguidor')
        EndTextCommandSetBlipName(chaserBlip)

        table.insert(especialChaserVehs, veh)
        table.insert(especialChaserPeds, ped)
        table.insert(especialChaserBlips, chaserBlip)
    end
end

-- ─── ESPECIAL: limpiar todos los autos hostiles ──────────────────────────
local function CleanEspecialChasers()
    especialCarsActive = false
    for _, v in ipairs(especialChaserVehs) do
        if DoesEntityExist(v) then DeleteEntity(v) end
    end
    for _, p in ipairs(especialChaserPeds) do
        if DoesEntityExist(p) then DeleteEntity(p) end
    end
    for _, b in ipairs(especialChaserBlips) do
        if DoesBlipExist(b) then RemoveBlip(b) end
    end
    especialChaserVehs  = {}
    especialChaserPeds  = {}
    especialChaserBlips = {}
end

-- ─── ESPECIAL: iniciar wave system ───────────────────────────────────────
local function StartEspecialWaves(grade, dropX, dropY, dropZ)
    if especialCarsActive then return end
    especialCarsActive = true

    NpcNotify('error', '¡Misión Especial!',
        'Enemigos en camino en ' .. (grade.firstWaveDelaySecs or 20) .. 's. ¡No te detengas!')

    especialWaveThread = Citizen.CreateThread(function()
        -- Esperar delay inicial antes de la 1ª wave
        local waited = 0
        while waited < (grade.firstWaveDelaySecs or 20) * 1000 and especialCarsActive do
            Citizen.Wait(500); waited = waited + 500
        end
        if not especialCarsActive then return end

        local maxCars   = grade.maxChaseCars      or 6
        local cooldown  = grade.waveCooldownSecs  or 20
        local despawnDist = grade.despawnDistToDrop or 50.0

        while especialCarsActive do
            -- Comprobar si hay que despawnear por proximidad al destino
            local pPos    = GetEntityCoords(PlayerPedId())
            local distDrop = #(pPos - vector3(dropX, dropY, dropZ))
            if distDrop <= despawnDist then
                CleanEspecialChasers()
                NpcNotify('success', '¡Llegaste!', 'Los perseguidores se retiraron.')
                return
            end

            -- Spawnear nueva wave si no se llegó al máximo
            local currentCount = #especialChaserVehs
            if currentCount < maxCars then
                SpawnEspecialChaserPair(grade)
                local newCount = #especialChaserVehs
                NpcNotify('error', '¡Nuevos perseguidores!',
                    'Han llegado más vehículos hostiles (' .. newCount .. '/' .. maxCars .. ').')
            end

            -- Limpiar vehículos/peds destruidos de las listas
            local aliveVehs = {}
            local alivePeds = {}
            local aliveBlips = {}
            for idx, v in ipairs(especialChaserVehs) do
                if DoesEntityExist(v) and GetEntityHealth(v) > 0 then
                    table.insert(aliveVehs, v)
                    if especialChaserPeds[idx] and DoesEntityExist(especialChaserPeds[idx]) then
                        table.insert(alivePeds, especialChaserPeds[idx])
                    end
                    if especialChaserBlips[idx] and DoesBlipExist(especialChaserBlips[idx]) then
                        table.insert(aliveBlips, especialChaserBlips[idx])
                    end
                else
                    -- Eliminar el blip del vehículo destruido
                    if especialChaserBlips[idx] and DoesBlipExist(especialChaserBlips[idx]) then
                        RemoveBlip(especialChaserBlips[idx])
                    end
                end
            end
            especialChaserVehs  = aliveVehs
            especialChaserPeds  = alivePeds
            especialChaserBlips = aliveBlips

            -- Esperar antes de la siguiente wave
            local ww = 0
            while ww < cooldown * 1000 and especialCarsActive do
                Citizen.Wait(500); ww = ww + 500
                -- Verificar distancia al drop en cada tick para despawnear a tiempo
                local pPos2    = GetEntityCoords(PlayerPedId())
                local distDrop2 = #(pPos2 - vector3(dropX, dropY, dropZ))
                if distDrop2 <= despawnDist then
                    CleanEspecialChasers()
                    NpcNotify('success', '¡Llegaste!', 'Los perseguidores se retiraron.')
                    return
                end
            end
        end
    end)
end

-- ─── Recibir lista de misiones diarias ───────
RegisterNetEvent('sh-taxijob:client:receiveDailyMissions', function(data)
    dailyMissionsOpen = true
    SetNuiFocus(true, true)
    SendNUIMessage({ action='openDailyMissions', missions=data.missions,
        msToReset=data.msToReset, playerLevel=data.playerLevel })
end)

-- ─── NUI: aceptar misión ─────────────────────
RegisterNUICallback('acceptNpcMission', function(d, cb)
    TriggerServerEvent('sh-taxijob:server:acceptNpcMission', d.missionId)
    cb('ok')
end)

-- ─── NUI: cerrar panel misiones ──────────────
RegisterNUICallback('closeDailyMissions', function(_, cb)
    dailyMissionsOpen = false
    SetNuiFocus(false, false)
    -- NO enviamos SendNUIMessage aquí para evitar el bucle:
    -- el JS ya ocultó el overlay antes de llamar a este callback
    cb('ok')
end)

-- ─── NUI: cancelar misión activa ─────────────
RegisterNUICallback('cancelNpcMission', function(d, cb)
    local missionId = (npcMission and npcMission.missionId) or (d and d.missionId)
    -- Limpiar NPC, blips, threads y estado local
    CleanNpcMission()
    -- Avisar al servidor para liberar activeMissions[cid] sin tocar la DB
    TriggerServerEvent('sh-taxijob:server:cancelNpcMission', { missionId = missionId })
    NpcNotify('info', 'Misión cancelada', 'La misión fue cancelada. Podés elegir otra.')
    -- Cerrar el panel de misiones diarias de la misma forma que la cruz de cerrar
    dailyMissionsOpen = false
    SetNuiFocus(false, false)
    SendNUIMessage({ action = 'forceCloseDailyMissions' })
    cb('ok')
end)

-- ─── Server inicia misión en el cliente ──────
RegisterNetEvent('sh-taxijob:client:startNpcMission', function(data)
    if npcMission then NpcNotify('error', 'Misión activa', 'Ya tenés una misión en curso.'); return end

    -- Resolver nombres de zona con los nativos de GTA (solo disponibles en cliente)
    data.pickupZone = GetStreetName(data.pickupX, data.pickupY, data.pickupZ)
    data.dropZone   = GetStreetName(data.dropX,   data.dropY,   data.dropZ)

    npcMission     = data
    missionBasePay = data.basePay or Config.NpcMissionBasePay or 2000
    missionCost    = missionBasePay
    local grade    = Config.MissionGrades[data.gradeKey] or {}

    --NpcNotify('info', 'Misión aceptada', 'Dirigite al punto de recogida.')
    SetNpcPickupBlip(data.pickupX, data.pickupY, data.pickupZ, 'Recoger pasajero')

    local dist = #(vector3(data.pickupX, data.pickupY, data.pickupZ) - vector3(data.dropX, data.dropY, data.dropZ))
    SendNUIMessage({ action='showNpcMissionPending', gradeLabel=grade.label or data.gradeKey,
        gradeColor=grade.color or '#9b59b6', pickupZone=data.pickupZone or 'Zona de recogida',
        dropZone=data.dropZone or 'Zona de entrega', distMeters=math.floor(dist),
        basePay=missionBasePay, hasTimer=grade.hasTimer or false, timerSecs=grade.timerSeconds or 0 })

    -- El NPC se spawnea al lado del jugador cuando llega al punto de recogida (1-3m)
    npcPed = 0

    npcMissionThread = Citizen.CreateThread(function()
            local stage       = 1
            local arrivedPick = false
            local pickedUp    = false
            local arrivedDrop = false

            while npcMission do
                -- En stage 3 necesitamos poll rápido para capturar la tecla E a tiempo
                if stage == 3 then Citizen.Wait(0) else Citizen.Wait(500) end
                local myPos = GetEntityCoords(PlayerPedId())

                if stage == 1 then
                    local pickCoords = vector3(data.pickupX, data.pickupY, data.pickupZ)
                    local npcPos    = (npcPed ~= 0 and DoesEntityExist(npcPed)) and GetEntityCoords(npcPed)
                                      or pickCoords
                    local distToNpc = #(myPos - npcPos)

                    if distToNpc < 5.0 and not arrivedPick then
                        arrivedPick = true
                        -- Spawnear el NPC a 1.5-2.5m al costado del jugador, mirando hacia él
                        local heading = GetEntityHeading(PlayerPedId())
                        local angle   = (heading + 180.0) * math.pi / 180.0
                        local offset  = 1.5 + math.random() * 1.0
                        local sx = myPos.x + math.cos(angle) * offset
                        local sy = myPos.y + math.sin(angle) * offset
                        local sz = myPos.z
                        local facing = heading  -- NPC mira al jugador
                        SpawnNpcPed(data.pedModel, sx, sy, sz, facing, function(ped)
                            npcPed = ped or 0
                        end)
                        NpcNotify('info', 'Llegaste', 'Espera que el Ciudadano se suba.')
                    end

                    if arrivedPick and not pickedUp and npcPed ~= 0 and DoesEntityExist(npcPed) then
                        local veh = GetVehiclePedIsIn(PlayerPedId(), false)
                        -- Recalcular distancia al NPC ya spawneado (no al punto del config)
                        local realNpcPos = GetEntityCoords(npcPed)
                        local realDist   = #(myPos - realNpcPos)
                        if DoesEntityExist(veh) and veh ~= 0 and realDist < 8.0 then
                            -- Buscar el primer asiento de pasajero libre (seat 0=copiloto, 1, 2...)
                            -- IsVehicleSeatFree con seat -1 es el conductor, lo saltamos siempre.
                            -- GetVehicleMaxNumberOfPassengers devuelve cuántos pasajeros caben
                            -- sin contar al conductor, así iteramos solo asientos válidos.
                            local maxPass   = GetVehicleMaxNumberOfPassengers(veh)
                            local freeSeat  = -1
                            for s = 0, math.max(maxPass - 1, 0) do
                                if IsVehicleSeatFree(veh, s) then
                                    freeSeat = s
                                    break
                                end
                            end
                            if freeSeat == -1 then
                                -- No hay asiento libre (raro), no intentar subir
                                goto continueLoop
                            end
                            -- TaskEnterVehicle con el seat confirmado libre: el NPC camina,
                            -- abre la puerta correspondiente y se sienta — animación nativa completa.
                            TaskEnterVehicle(npcPed, veh, 10000, freeSeat, 1.0, 0, 0)
                            local t = 0
                            while t < 8000 do
                                Citizen.Wait(200); t = t + 200
                                if GetVehiclePedIsIn(npcPed, false) == veh then break end
                            end
                            if GetVehiclePedIsIn(npcPed, false) ~= veh then
                                -- Fallback directo si la animación no completó
                                SetPedIntoVehicle(npcPed, veh, freeSeat)
                                Citizen.Wait(400)
                            end
                            if GetVehiclePedIsIn(npcPed, false) == veh or realDist < 5.0 then
                                pickedUp = true; stage = 2
                                npcUIActive = true
                                if DoesBlipExist(npcBlip) then RemoveBlip(npcBlip) end
                                SetNpcDropBlip(data.dropX, data.dropY, data.dropZ, 'Entregar pasajero')
                                if grade.hasTimer and (grade.timerSeconds or 0) > 0 then
                                    missionTimerLeft = grade.timerSeconds
                                    missionTimerThread = Citizen.CreateThread(function()
                                        while missionTimerLeft > 0 and npcUIActive do
                                            Citizen.Wait(1000); missionTimerLeft = missionTimerLeft - 1
                                        end
                                    end)
                                end
                                StartBarsThread()
                                -- ── ESPECIAL: iniciar waves de autos hostiles ──
                                if data.gradeKey == 'Especial' then
                                    Citizen.SetTimeout((grade.firstWaveDelaySecs or 20) * 1000 - 2000, function()
                                        -- El setTimeout se lanza desde ahora; StartEspecialWaves
                                        -- maneja su propio delay interno, así que le pasamos 0
                                        -- para que arranque de inmediato dentro de la función.
                                    end)
                                    StartEspecialWaves(grade, data.dropX, data.dropY, data.dropZ)
                                end
                                SendNUIMessage({ action='showNpcTripUI', gradeLabel=grade.label or data.gradeKey,
                                    gradeColor=grade.color or '#9b59b6', dropZone=data.dropZone or 'Destino',
                                    basePay=missionBasePay, hasTimer=grade.hasTimer or false, timerSecs=grade.timerSeconds or 0 })
                                NpcNotify('info', '¡Pasajero a bordo!', 'Llevalo a ' .. (data.dropZone or 'el destino'))
                            end
                        end
                    end
                    ::continueLoop::

                elseif stage == 2 then
                    local distToDrop = #(myPos - vector3(data.dropX, data.dropY, data.dropZ))
                    if distToDrop < 12.0 and not arrivedDrop then
                        arrivedDrop = true
                        npcUIActive = false

                        local finalPay = missionCost
                        if stressLocked         then finalPay = math.floor(finalPay * (1 - (Config.StressBars.penaltyStress  or 25) / 100)); penaltyStressApplied = true end
                        if penaltyScaredApplied then finalPay = math.floor(finalPay * (1 - (Config.StressBars.penaltyScared or 25) / 100)) end
                        local timedBonus = false
                        if grade.hasTimer and (grade.timerSeconds or 0) > 0 and missionTimerLeft > 0 then
                            finalPay = math.floor(finalPay * (1 + (grade.bonusPct or 0) / 100)); timedBonus = true
                        end

                        -- ═══════════════════════════════════════════════════════
                        --  LÓGICA AVANZADO: 50% paga / 50% huye y hay persecución
                        -- ═══════════════════════════════════════════════════════
                        local isAvanzado  = (data.gradeKey == 'Avanzado')
                        local isEspecial  = (data.gradeKey == 'Especial')
                        local runaway     = false

                        -- Calcular propina penalizada (Especial y Avanzado)
                        -- Aplica los mismos factores de penalización que finalPay
                        local baseTip = grade.tipAmount or 0
                        local tipAmountFinal = baseTip
                        if baseTip > 0 then
                            if stressLocked         then tipAmountFinal = math.floor(tipAmountFinal * (1 - (Config.StressBars.penaltyStress  or 25) / 100)) end
                            if penaltyScaredApplied then tipAmountFinal = math.floor(tipAmountFinal * (1 - (Config.StressBars.penaltyScared or 25) / 100)) end
                        end

                        if isAvanzado then
                            -- 50% de probabilidad de que el NPC no pague
                            runaway = (math.random() <= (grade.runawayChance or 0.5))
                        elseif isEspecial then
                            -- Especial: nunca huye, siempre paga
                            runaway = false
                            -- Limpiar autos hostiles al llegar al destino
                            CleanEspecialChasers()
                        else
                            -- Lógica original para Básico (hasProbRunaway=true)
                            if grade.hasProbRunaway and math.random() <= (grade.runawayChance or 0.6) then
                                runaway = true
                            end
                        end

                        -- Notificar al servidor del resultado del viaje
                        TriggerServerEvent('sh-taxijob:server:finishNpcMission', {
                            missionId=data.missionId, gradeKey=data.gradeKey, finalPay=finalPay,
                            runaway=runaway, timedBonus=timedBonus, meters=distanceMeter,
                            isAvanzadoChase = isAvanzado and runaway,
                            isEspecial      = isEspecial,
                            tipAmountFinal  = tipAmountFinal })

                        if DoesEntityExist(npcPed) and npcPed ~= 0 then
                            if runaway then
                                -- El NPC sale del vehículo CAMINANDO (no corriendo aún)
                                TaskLeaveVehicle(npcPed, GetVehiclePedIsIn(npcPed, false), 0)
                                -- Sin armas, pero SÍ puede defenderse a puñetazos si lo golpean
                                RemoveAllPedWeapons(npcPed, true)
                                SetPedDropsWeaponsWhenDead(npcPed, false)
                                -- Permitir combate cuerpo a cuerpo (defensa con puños)
                                SetPedCombatAttributes(npcPed, 46, true)   -- puede pelear si lo atacan
                                SetPedCombatAttributes(npcPed, 5,  false)  -- no persigue al jugador por su cuenta
                                SetPedCombatAttributes(npcPed, 17, false)  -- no usa cobertura
                                SetPedCombatRange(npcPed, 0)               -- rango mínimo (solo reacciona si lo tocan)
                                SetPedFleeAttributes(npcPed, 0, false)
                                -- Mantener como entidad de misión para que NO desaparezca
                                SetEntityAsMissionEntity(npcPed, true, true)
                                SetBlockingOfNonTemporaryEvents(npcPed, true)

                                if isAvanzado then
                                    -- ── MISIÓN AVANZADA: camina 2s, luego corre ──
                                    local chaseSecs = grade.chaseTimerSecs or 30

                                    -- Blip rojo SOBRE el NPC (se actualiza en tiempo real en stage 3)
                                    if DoesBlipExist(chaseBlip) then RemoveBlip(chaseBlip) end
                                    chaseBlip = AddBlipForEntity(npcPed)
                                    SetBlipSprite(chaseBlip, 1)
                                    SetBlipColour(chaseBlip, 1)      -- 1 = rojo
                                    SetBlipScale(chaseBlip, 1.0)
                                    SetBlipAsShortRange(chaseBlip, false)
                                    SetBlipRoute(chaseBlip, true)
                                    SetBlipRouteColour(chaseBlip, 1)
                                    BeginTextCommandSetBlipName('STRING')
                                    AddTextComponentString('Civil sin pagar')
                                    EndTextCommandSetBlipName(chaseBlip)

                                    chaseNpcPed    = npcPed
                                    chaseActive    = true
                                    chaseTimerLeft = chaseSecs

                                    -- ── Thread de insultos: el NPC grita mientras huye ──
                                    Citizen.CreateThread(function()
                                        local insults = {
                                            'WOOOOAH_WOOOOAH_WOOOOAH',
                                            'GENERIC_CURSE_HIGH',
                                            'GENERIC_CURSE_MED',
                                            'GENERIC_INSULT_HIGH',
                                            'GENERIC_INSULT_MED',
                                            'GENERIC_SHOCKED_HIGH',
                                            'GENERIC_FRIGHTENED_HIGH',
                                            'GENERIC_FRIGHTENED_MED',
                                            'GENERIC_HOWS_MY_DRIVING',
                                            'GENERIC_FUCK_YOU',
                                            'GENERIC_BYE',
                                            'GENERIC_CHAT',
                                            'GENERIC_INSULT_LOW',
                                            'GENERIC_CURSE_LOW',
                                        }
                                        -- Pequeño delay para que el NPC termine de bajar del vehículo
                                        Citizen.Wait(2000)
                                        while chaseActive and DoesEntityExist(npcPed) and npcPed ~= 0 do
                                            local line = insults[math.random(#insults)]
                                            PlayAmbientSpeech1(npcPed, line, 'SPEECH_PARAMS_FORCE_SHOUTED', 0)
                                            -- Intervalo aleatorio entre insultos: 2.5 a 5 segundos
                                            Citizen.Wait(math.random(2500, 5000))
                                        end
                                    end)

                                    NpcNotify('error', 'El civil se fue sin pagar',
                                        'Recupera el pago antes de que huya — ' .. chaseSecs .. 's')

                                    -- Mostrar temporizador de persecución en la UI
                                    SendNUIMessage({ action='showChaseTimer',
                                        timerSecs=chaseSecs, gradeColor=grade.color or '#e74c3c' })

                                    -- Esperar que el NPC salga del vehículo (máx 1.8s) y luego CORRER LENTO
                                    Citizen.SetTimeout(1800, function()
                                        if not (DoesEntityExist(npcPed) and npcPed ~= 0) then return end

                                        -- Thread de fuga con navmesh: recalcula cada 3s usando
                                        -- TaskSmartFleePed que sí esquiva paredes y obstáculos.
                                        -- La velocidad se limita con SetPedMaxMoveBlendRatio para
                                        -- que trote rápido pero el jugador pueda alcanzarlo.
                                        Citizen.CreateThread(function()
                                            while chaseActive and DoesEntityExist(npcPed) and npcPed ~= 0 do
                                                -- SmartFlee usa el navmesh: dobla esquinas, evita paredes
                                                TaskSmartFleePed(npcPed, PlayerPedId(), 200.0, 3000, false, true)
                                                -- Limitar velocidad: 1.0 = trote rápido, alcanzable corriendo
                                                SetPedMaxMoveBlendRatio(npcPed, 1.0)
                                                SetEntityAsMissionEntity(npcPed, true, true)
                                                Citizen.Wait(3000)
                                            end
                                        end)
                                    end)

                                    -- Thread contador de la persecución
                                    chaseTimerThread = Citizen.CreateThread(function()
                                        while chaseTimerLeft > 0 and chaseActive do
                                            Citizen.Wait(1000)
                                            chaseTimerLeft = chaseTimerLeft - 1
                                            SendNUIMessage({ action='updateChaseTimer', timerLeft=chaseTimerLeft })
                                        end
                                        if chaseActive then
                                            -- Tiempo expirado sin atrapar al NPC
                                            chaseActive = false
                                            if DoesBlipExist(chaseBlip) then RemoveBlip(chaseBlip) end
                                            chaseBlip = 0
                                            NpcNotify('error', 'El civil ha huido',
                                                'No pudiste recuperar el pago. Igual ganás algo de XP.')
                                            TriggerServerEvent('sh-taxijob:server:advancedChaseFailed',
                                                { missionId=data.missionId })
                                            SendNUIMessage({ action='hideChaseTimer' })
                                            Citizen.Wait(3000); CleanNpcMission()
                                        end
                                    end)

                                    -- Entrar en stage 3: esperar que el jugador llegue al NPC
                                    stage = 3

                                    -- ── Thread de render dedicado para stage 3 ──
                                    -- Corre cada frame (Wait 0) para que el parpadeo
                                    -- de la [E] y el texto "SIN PAGAR" sean fluidos.
                                    -- Se auto-termina cuando chaseActive = false.
                                    Citizen.CreateThread(function()
                                        while chaseActive and DoesEntityExist(chaseNpcPed) and chaseNpcPed ~= 0 do
                                            Citizen.Wait(0)
                                            local rNpcPos = GetEntityCoords(chaseNpcPed)
                                            local rMyPos  = GetEntityCoords(PlayerPedId())
                                            local rDist   = #(rMyPos - rNpcPos)
                                            local rTackle = (grade.tackleDistance or Config.TackleDistance or 3.0)

                                            -- [E] persistente: siempre visible dentro del rango
                                            if rDist <= rTackle then
                                                SetDrawOrigin(rNpcPos.x, rNpcPos.y, rNpcPos.z + 1.0, 0)
                                                SetTextFont(0); SetTextScale(0, 0.30); SetTextProportional(1)
                                                SetTextOutline(); SetTextColour(255, 220, 0, 255)
                                                SetTextEntry('STRING'); SetTextCentre(true)
                                                AddTextComponentString('[E] Tacklear')
                                                DrawText(0, 0); ClearDrawOrigin()
                                            end
                                        end
                                    end)
                                else
                                    -- Básico: huye sin persecución (comportamiento original)
                                    Citizen.SetTimeout(1800, function()
                                        if DoesEntityExist(npcPed) and npcPed ~= 0 then
                                            TaskSmartFleePed(npcPed, PlayerPedId(), 200.0, -1, false, false)
                                        end
                                    end)
                                    NpcNotify('error', '¡Se escapó sin pagar!', 'El pasajero salió corriendo. No recibirás el pago.')
                                    Citizen.Wait(3000); CleanNpcMission(); return
                                end
                            else
                                -- NPC paga normalmente (Básico / Intermedio / Especial)
                                TaskLeaveVehicle(npcPed, GetVehiclePedIsIn(npcPed, false), 0)
                                local bonusPct  = grade.bonusPct or 0
                                local penStress = Config.StressBars.penaltyStress  or 25
                                local penScared = Config.StressBars.penaltyScared  or 25
                                local tipMsg    = ''
                                if isEspecial and tipAmountFinal > 0 then
                                    tipMsg = ' + Propina $' .. tipAmountFinal
                                end
                                NpcNotify('success', '¡Viaje completado!', 'El pasajero pagó $' .. finalPay .. tipMsg ..
                                    (timedBonus and ' (+' .. bonusPct .. '% bonus tiempo)' or '') ..
                                    (penaltyScaredApplied and ' (-' .. penScared .. '% susto)' or '') ..
                                    (penaltyStressApplied and ' (-' .. penStress .. '% stress)' or ''))
                                Citizen.Wait(3000); CleanNpcMission(); return
                            end
                        end
                    end

                -- ══════════════════════════════════════════════════════
                --  STAGE 3 — PERSECUCIÓN AVANZADA: tackleo con tecla E
                --  Render (SIN PAGAR + [E] parpadeante) → thread dedicado.
                --  Este bloque solo maneja el INPUT de la tecla E.
                -- ══════════════════════════════════════════════════════
                elseif stage == 3 then
                    if not chaseActive then return end

                    if DoesEntityExist(chaseNpcPed) and chaseNpcPed ~= 0 then
                        local npcPos    = GetEntityCoords(chaseNpcPed)
                        local distToNpc = #(myPos - npcPos)
                        local tackleDist = (grade.tackleDistance or Config.TackleDistance or 3.0)

                        if distToNpc <= tackleDist then
                            -- INPUT_CONTEXT = tecla E (PC) / botón X (gamepad)
                            if IsControlJustReleased(0, 38) and not IsPedInAnyVehicle(PlayerPedId(), false) then
                                -- ── Iniciar tackle ──
                                chaseActive = false
                                if DoesBlipExist(chaseBlip) then RemoveBlip(chaseBlip) end
                                chaseBlip = 0

                                local myPed = PlayerPedId()

                                -- Parar la fuga del NPC inmediatamente
                                ClearPedTasks(chaseNpcPed)
                                SetBlockingOfNonTemporaryEvents(chaseNpcPed, true)
                                FreezeEntityPosition(chaseNpcPed, true)

                                -- Cargar animación
                                local dictTackle = 'missmic2ig_11'
                                RequestAnimDict(dictTackle)
                                local tw = 0
                                while not HasAnimDictLoaded(dictTackle) do
                                    Citizen.Wait(10); tw = tw + 10
                                    if tw > 3000 then break end
                                end

                                -- Acoplar NPC al jugador y reproducir animación de impacto en el NPC
                                FreezeEntityPosition(chaseNpcPed, false)
                                AttachEntityToEntity(chaseNpcPed, myPed, 11816,
                                    0.25, 0.5, 0.0, 0.5, 0.5, 180.0,
                                    false, false, false, false, 2, false)
                                TaskPlayAnim(chaseNpcPed, dictTackle, 'mic_2_ig_11_intro_p_one',
                                    8.0, -8.0, 3000, 0, 0, false, false, false)

                                -- Animación del jugador (tackle)
                                TaskPlayAnim(myPed, dictTackle, 'mic_2_ig_11_intro_goon',
                                    8.0, -8.0, 3000, 0, 0, false, false, false)

                                Citizen.Wait(2200)
                                DetachEntity(chaseNpcPed, true, false)

                                -- Ragdoll del NPC tras el impacto
                                SetPedCanRagdoll(chaseNpcPed, true)
                                SetPedToRagdoll(chaseNpcPed, 3000, 3000, 0, 0, 0, 0)

                                -- Ragdoll breve del jugador (se cae también)
                                local doRagdoll = true
                                Citizen.CreateThread(function()
                                    while doRagdoll do
                                        Citizen.Wait(5)
                                        SetPedToRagdoll(myPed, 800, 800, 0, 0, 0, 0)
                                    end
                                end)
                                Citizen.Wait(1200)
                                doRagdoll = false

                                -- Acreditar propina penalizada y terminar
                                local tipAmt = grade.tipAmount or 500
                                -- Aplicar penalizaciones acumuladas al monto de la propina
                                if stressLocked         then tipAmt = math.floor(tipAmt * (1 - (Config.StressBars.penaltyStress  or 25) / 100)) end
                                if penaltyScaredApplied then tipAmt = math.floor(tipAmt * (1 - (Config.StressBars.penaltyScared or 25) / 100)) end
                                
                                TriggerServerEvent('sh-taxijob:server:advancedChaseSuccess',
                                    { missionId=data.missionId, tipAmount=tipAmt })
                                SendNUIMessage({ action='hideChaseTimer' })
                                Citizen.Wait(1500); CleanNpcMission(); return
                            end
                        end
                    else
                        -- NPC desapareció → misión fallida
                        if chaseActive then
                            chaseActive = false
                            NpcNotify('error', 'El civil escapó', 'No pudiste recuperar el pago.')
                            TriggerServerEvent('sh-taxijob:server:advancedChaseFailed',
                                { missionId=data.missionId })
                            SendNUIMessage({ action='hideChaseTimer' })
                        end
                        Citizen.Wait(2000); CleanNpcMission(); return
                    end
                end
            end
            CleanNpcMission()
        end)
end)

-- ─── Cancelar misión NPC ─────────────────────
RegisterNetEvent('sh-taxijob:client:cancelNpcMission', function()
    if npcMission then NpcNotify('error', 'Misión cancelada', 'La misión fue cancelada.'); CleanNpcMission() end
end)

-- ─── Timer diario → NUI ──────────────────────
RegisterNetEvent('sh-taxijob:client:updateDailyTimer', function(msToReset)
    SendNUIMessage({ action = 'updateDailyTimer', msToReset = msToReset })
end)

-- ─── Abrir UI misiones (desde target) ────────
RegisterNetEvent('sh-taxijob:client:openDailyMissionsUI', function()
    if not hasAccess or not isOnDuty then
        Notify('error', 'Sin acceso', 'Necesitás estar de servicio para ver las misiones.')
        return
    end
    TriggerServerEvent('sh-taxijob:server:requestDailyMissions')
end)

-- ─── Zona de target: misiones diarias ────────
-- (manejado directamente por RegisterDailyMissionsZone en UpdateTargetZones)
-- Este evento queda como respaldo para compatibilidad
RegisterNetEvent('sh-taxijob:client:addDailyMissionsZone', function(locData)
    if not locData then return end
    -- Actualizar jobLocations y re-registrar la zona
    if not jobLocations.viajes_diarios then
        jobLocations.viajes_diarios = { x=locData.x, y=locData.y, z=locData.z, heading=locData.heading or 0 }
    end
    RegisterDailyMissionsZone()
end)

-- ─── Marcador visual: misiones diarias ───────
-- (respaldo: si el server manda injectDailyMarker lo agrega igual)
RegisterNetEvent('sh-taxijob:client:injectDailyMarker', function(locData)
    if not locData then return end
    for i = #activeMarkers, 1, -1 do
        if activeMarkers[i].locType == 'viajes_diarios' then table.remove(activeMarkers, i) end
    end
    table.insert(activeMarkers, { locType='viajes_diarios', coords=vector3(locData.x, locData.y, locData.z) })
    StartMarkerThread()
end)

print('[sh-taxijob] Cliente v5 + NPC Missions OK.')

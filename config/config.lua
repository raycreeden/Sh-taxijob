Config = {}
Config.Framework  = 'auto'
Config.Inventory  = 'auto'
Config.Target     = 'auto'
Config.Clothing   = 'auto'
Config.JobName    = 'taxijob'
Config.JobLabel   = 'Taxi'

-- ── Stash persistente (almacén del job) ──────────────────────────
-- StashName   → identificador único del stash en la base de datos
-- StashLabel  → nombre visible en qb-inventory
-- StashSlots  → cantidad de slots del stash
-- StashWeight → peso máximo en gramos (100000 = 100 kg)
Config.StashName   = 'sh_taxijob_stash'
Config.StashLabel  = 'Almacén Taxi'
Config.StashSlots  = 50
Config.StashWeight = 100000

Config.Grades = {
    [0]={name='conductor',  label='Conductor',  salary=500 },
    [1]={name='senior',     label='Senior',     salary=800 },
    [2]={name='supervisor', label='Supervisor', salary=1200},
    [3]={name='subjefe',    label='Sub-Jefe',   salary=2000},
    [4]={name='jefe',       label='Jefe',       salary=3000},
}
Config.DefaultGrade   = 4
Config.SalaryInterval = 1
Config.TargetDistance = 3.0

Config.Locations = {
    stash      = { coords=vector3(905.8, -176.8, 74.2), heading=250.0 },
    clothing   = { coords=vector3(911.3, -179.6, 74.2), heading=250.0 },
    spawn      = { coords=vector3(908.5, -183.0, 74.2), heading=250.0 },
    spawnpoint = { coords=vector3(912.0, -188.0, 74.2), heading=250.0 },
}

Config.DefaultMarker = {
    markerType=1, colorName='Celeste',
    r=80, g=180, b=255, a=160, scaleXY=1.5, scaleZ=0.5,
    drawDistance=6,
}

Config.SpawnVehicles = {
    { model='taxi',    label='Taxi Cruiser',   minLevel=0, price=500 },
    { model='eudora',     label='Eudora',         minLevel=3, price=1000 },
    { model='broadway', label='Broadway Coupe',      minLevel=6, price=2000 },
    { model='minivan', label='Minivan Taxi',   minLevel=10, price=3000},
}

Config.VehicleMods = {
    ["taxi"] = {
        color = {42, 42},
        rimColor = 12,
        livery = 0,
        wheels = { type = 10, index = 10 },
        mods = {
            [0] = -1, [1] = -1, [2] = -1, [3] = -1, [4] = -1, [48] = -1,
        },
        extras = {
            [1]=false,[2]=false,[3]=false,[4]=false,[5]=true,[6]=false,[7]=false,[8]=false,[9]=false,[10]=true,[11]=true,[12]=false,[13]=false,
        },
    },
    ["eudora"] = {
        color = {12, 12},
        rimColor = 12,
        livery = 10,
        wheels = { type = 10, index = 10 },
        mods = {
            [0]=-1,[1]=5,[2]=3,[3]=-1,[4]=6,[5]=-1,[6]=8,[7]=1,[9]=1,[48]=10,
        },
        extras = {
            [1]=false,[2]=false,[3]=false,[4]=false,[5]=false,[6]=false,[7]=false,[8]=false,[9]=false,[10]=false,[11]=false,[12]=false,[13]=false,
        },
    },
        ["broadway"] = {
        color = {12, 12},
        rimColor = 12,
        livery = 11,
        wheels = { type = 10, index = 10 },
        mods = {
            [0]=-1,[1]=5,[2]=4,[3]=-1,[4]=0,[5]=2,[6]=-1,[7]=5,[8]=2,[9]=-1,[10]=-1,[48]=11,
        },
        extras = {
            [1]=true,[2]=true,[3]=false,[4]=false,[5]=false,[6]=false,[7]=false,[8]=false,[9]=false,[10]=false,[11]=false,[12]=false,[13]=false,
        },
    },
}

Config.TripDefaults = {
    basePrice    = 1500,
    pricePerUnit = 70,
    unitMeters   = 40,
}

Config.TipOptions = { 500, 1000, 2000, 5000 }

Config.XpPerTrip = { min=50, max=200 }

Config.Levels = {
    [0]  = { xpRequired=0,    label='Aprendiz'   },
    [1]  = { xpRequired=100,  label='Conductor'  },
    [2]  = { xpRequired=250,  label='Experimentado'},
    [3]  = { xpRequired=500,  label='Veterano'   },
    [4]  = { xpRequired=900,  label='Experto'    },
    [5]  = { xpRequired=1400, label='Profesional'},
    [6]  = { xpRequired=2000, label='Élite'      },
    [7]  = { xpRequired=2700, label='Maestro'    },
    [8]  = { xpRequired=3500, label='Gran Maestro'},
    [9]  = { xpRequired=4500, label='Leyenda'    },
    [10] = { xpRequired=6000, label='Taxi Driver'},
}

Config.DefaultPermissions = {
    --  Panel:      ubicaciones  vehiculos  salarios  viajes_config  invitar  empresa  viajes_realizados  empleados  alertas_config
    [0] = { ubicaciones=false, vehiculos=false, salarios=false, viajes_config=false, invitar=false, empresa=false, viajes_realizados=false, empleados=false, alertas_config=false },
    [1] = { ubicaciones=false, vehiculos=false, salarios=false, viajes_config=false, invitar=false, empresa=false, viajes_realizados=false, empleados=false, alertas_config=false },
    [2] = { ubicaciones=false, vehiculos=false, salarios=false, viajes_config=false, invitar=false, empresa=false, viajes_realizados=true,  empleados=false, alertas_config=false },
    [3] = { ubicaciones=true,  vehiculos=true,  salarios=false, viajes_config=true,  invitar=true,  empresa=false, viajes_realizados=true,  empleados=true,  alertas_config=true  },
    [4] = { ubicaciones=true,  vehiculos=true,  salarios=true,  viajes_config=true,  invitar=true,  empresa=true,  viajes_realizados=true,  empleados=true,  alertas_config=true  },
}

Config.EmployeeManagementPerms = {
    [0] = false,
    [1] = false,
    [2] = false,
    [3] = true,
    [4] = true,
}

Config.Hotkeys = {
    [1] = 'o',
    [2] = 'i',
    [3] = 'u',
    [4] = 'j',
    [5] = '-',
    [6] = 'i',
    [7] = 'o',
}

-- ═══════════════════════════════════════════════════════════════
--  ALERTAS CONFIG
--  Controla la apariencia y posición de dos elementos de UI:
--
--  1) TripNotify  → alerta que recibe el TAXISTA cuando un civil
--                   pide un taxi (la tarjeta violeta con Aceptar/Ignorar)
--
--  2) ClientUI    → interfaz que ve el CIVIL durante el viaje
--                   (costo, propinas, cambio de destino)
--
--  ── POSICIONES DISPONIBLES ──────────────────────────────────
--  Para TripNotify  → 'top-right' | 'top-left' | 'top-center'
--                     'center-right' | 'center-left' | 'center'
--                     'bottom-right' | 'bottom-left' | 'bottom-center'
--
--  Para ClientUI    → 'top-right' | 'top-left'
--                     'bottom-right' | 'bottom-left'
--                     'bottom-center' | 'top-center'
--
--  ── PERSISTENCIA ────────────────────────────────────────────
--  persistent = true  → se guarda en la base de datos (sobrevive
--                       reinicios del server o del recurso)
--  persistent = false → solo vive en memoria, se pierde al reiniciar
--
--  ── QUIÉN PUEDE EDITAR DESDE LA TABLET ──────────────────────
--  Controlado por Config.DefaultPermissions → panel 'alertas_config'
--  Grados con alertas_config=true pueden modificarlo desde la tablet.
--  El propietario (isOwner) siempre puede editarlo.
-- ═══════════════════════════════════════════════════════════════
Config.AlertasConfig = {

    -- ── Alerta de viaje (taxista) ───────────────────────────
    TripNotify = {
        -- Posición en pantalla de la tarjeta de alerta
        -- Valores: 'top-right' | 'top-left' | 'top-center'
        --          'center-right' | 'center-left' | 'center'
        --          'bottom-right' | 'bottom-left' | 'bottom-center'
        position   = 'top-right',

        -- Duración en milisegundos antes de que desaparezca sola (0 = no desaparece)
        duration   = 20000,

        -- Guarda los cambios en la base de datos (true) o solo en memoria (false)
        persistent = true,
    },

    -- ── Interfaz del civil durante el viaje ─────────────────
    ClientUI = {
        -- Posición del panel de viaje del civil
        -- Valores: 'top-right' | 'top-left'
        --          'bottom-right' | 'bottom-left'
        --          'bottom-center' | 'top-center'
        position   = 'bottom-right',

        -- Guarda los cambios en la base de datos (true) o solo en memoria (false)
        persistent = true,
    },
}

Config.BoardNotes = {
    DrawDistance = 5.0 }
Config.BoardNoteHeight = 0.9

Config.StashName      = 'sh_taxijob_stash'
Config.StashSlots     = 50
Config.StashWeight    = 100000
Config.NotifyDuration = 5000
Config.Debug          = false  -- true: muestra todos los prints del server | false: solo errores críticos y versión

Config.MaxServiceLogs = 50
Config.MaxTripHistory = 15
-------------------------------------
-------------------------------------

-- ── Ubicación del marcador de Misiones Diarias ───────────────
-- Aparece como una ubicación más en el panel de "Ubicaciones"
-- Podés setear las coordenadas desde la tablet igual que el resto.
Config.Locations.viajes_diarios = {
    coords  = vector3(911.0, -175.0, 74.2),
    heading = 250.0,
}

-- ── Cooldown de reinicio de misiones diarias (en segundos) ───
-- 86400 = 24 horas reales. El timer sigue corriendo aunque el
-- jugador se desconecte (se guarda en SQL con timestamp absoluto).
Config.DailyMissionResetSeconds = 86400

-- ── Máximo de misiones visibles en la interfaz ───────────────
Config.DailyMissionMaxVisible = 10

-- ── Definición de GRADOS de misión ───────────────────────────
--  levelRequired  → nivel mínimo del jugador para ver este grado
--  missionCount   → cuántas misiones se generan por ciclo
--  baseMultiplier → multiplicador sobre el pago base (1.0 = normal)
--  hasProbRunaway → true = hay chance de que el NPC huya sin pagar
--  runawayChance  → probabilidad de fuga (0.0 a 1.0)
--  hasTimer       → true = hay cronómetro de entrega
--  timerSeconds   → tiempo en segundos para llegar al destino
--  bonusPct       → bonus % si se llega antes del timer (0 = sin bonus)
--  payToSociety   → true = el pago va a la cuenta empresa, false = al jugador
Config.MissionGrades = {
    Basico = {
        levelRequired  = 0,
        missionCount   = 5,
        baseMultiplier = 1.0,   -- Multiplicador de XP (no afecta el pago)
        payMultiplier  = 0.5,   -- ← NUEVO: multiplicador del pago final (ajustá a gusto)
                                --   Ejemplo: NpcMissionBasePay=100, payMultiplier=0.5 → pago base $50
        hasProbRunaway = true,
        runawayChance  = 0.1,   -- Probabilidad de fuga (0.0 a 1.0)
        hasTimer       = false,
        timerSeconds   = 0,
        bonusPct       = 0,
        payToSociety   = true,
        label          = 'Básico',
        color          = '#9b59b6',
    },
    Intermedio = {
        levelRequired  = 3,
        missionCount   = 5,
        baseMultiplier = 1.5,   -- Multiplicador de XP
        payMultiplier  = 0.5,   -- ← NUEVO: multiplicador del pago final
                                --   Ejemplo: NpcMissionBasePay=100, payMultiplier=1.0 → pago base $150 (con baseMultiplier)
        hasProbRunaway = false,
        runawayChance  = 0.0,
        hasTimer       = true,
        timerSeconds   = 90,
        bonusPct       = 20,    -- +20% si llegás antes del timer
        payToSociety   = true,
        label          = 'Intermedio',
        color          = '#27ae60',
    },
    Avanzado = {
        levelRequired  = 6,
        missionCount   = 5,
        baseMultiplier = 2.0,   -- Multiplicador de XP (más XP que Básico e Intermedio)
        payMultiplier  = 1.0,   -- Multiplicador del pago base (mayor que los otros grados)
                                --   Ejemplo: NpcMissionBasePay=20, payMultiplier=1.2 → pago base $48
        hasProbRunaway = true,  -- Combinado: tiene fuga Y timer (igual que Básico e Intermedio juntos)
        runawayChance  = 0.9,   -- 50% de chance de que el NPC no pague al llegar al destino
        hasTimer       = true,  -- También tiene cronómetro como Intermedio
        timerSeconds   = 120,   -- Tiempo en segundos para completar el viaje
        bonusPct       = 25,    -- +25% si llegás antes del timer (solo si el NPC paga)
        payToSociety   = true,  -- El pago base siempre va a la cuenta bancaria (empresa)
        tipPayToBank   = true,  -- La propina (recuperar pago) también va a la cuenta bancaria
        chaseTimerSecs = 30,    -- Segundos para perseguir y atrapar al NPC que huyó sin pagar
        tipAmount      = 200,   -- Propina fija que se acredita en banco si atrapás al NPC
        tackleDistance = 3.0,   -- Distancia máxima (metros) para que aparezca el prompt [E] Tacklear
        label          = 'Avanzado',
        color          = '#e74c3c',  -- Rojo distintivo para misiones Avanzadas
    },

    -- ═══════════════════════════════════════════════════════════════
    --  GRADO ESPECIAL — Nivel 10 requerido
    --  Característica única: una vez que el NPC sube al taxi, a los
    --  N segundos comienzan a aparecer vehículos hostiles que embisten
    --  al jugador. Cada wave agrega 2 autos más, hasta el máximo.
    --  Los autos desaparecen cuando el taxi se acerca al destino final.
    -- ═══════════════════════════════════════════════════════════════
    Especial = {
        levelRequired  = 10,
        missionCount   = 3,     -- Misiones Especiales generadas por ciclo diario
        baseMultiplier = 3.0,   -- Multiplicador de XP (el más alto)
        payMultiplier  = 1.8,   -- Multiplicador del pago base (superior a Avanzado)
        hasProbRunaway = false, -- El NPC NO huye (la dificultad son los autos hostiles)
        runawayChance  = 0.0,
        hasTimer       = true,  -- Tiene cronómetro
        timerSeconds   = 180,   -- 3 minutos para completar el viaje
        bonusPct       = 30,    -- +30% bonus si llegás antes del timer
        payToSociety   = true,  -- Pago va a la cuenta empresa
        tipAmount      = 350,   -- Propina adicional por completar (se suma al finalizar)
        label          = 'Especial',
        color          = '#f39c12',  -- Naranja dorado — no usado por ningún otro grado

        -- ── Parámetros de la persecución de autos hostiles ──────
        -- firstWaveDelaySecs  → segundos DESDE que el NPC sube hasta que llega la 1ª wave
        firstWaveDelaySecs  = 20,
        -- waveCooldownSecs    → segundos entre cada wave de 2 autos adicionales
        waveCooldownSecs    = 20,
        -- maxChaseCars        → máximo de autos hostiles simultáneos (múltiplo de 2)
        maxChaseCars        = 6,
        -- despawnDistToDrop   → distancia al destino final (metros) en la que desaparecen todos los autos
        despawnDistToDrop   = 50.0,
        -- chaseCarsModels     → modelos de vehículo que pueden spawnear como perseguidores
        chaseCarsModels     = { 'sultan', 'dominator', 'kuruma', 'sentinel', 'oracle2' },
        -- chaserPedModels     → modelos de ped para los conductores hostiles
        chaserPedModels     = { 'g_m_y_lost_01', 'g_m_y_lost_02', 'g_m_y_maraboyz_01', 'g_m_y_ballaorig_01' },
    },
}

-- ── Distancia de tacleo (misión Avanzada) ────────────────────
-- Distancia en metros desde la cual aparece el prompt [E] Recuperar pago.
-- Podés sobreescribir por grado con tackleDistance dentro de MissionGrades.Avanzado
Config.TackleDistance = 3.0

-- ── Probabilidad de aparición de misiones mixtas ─────────────
-- A partir del nivel 3 hay 50% de Básico y 50% de Intermedio.
-- Modificá estas chances como quieras.
Config.MissionMixChances = {
    -- [nivel_minimo] = { {grado, chance}, ... }  (chances suman 1.0)
    [0]  = { { grade='Basico', chance=1.0 } },
    [3]  = { { grade='Basico', chance=0.5 }, { grade='Intermedio', chance=0.5 } },
    [6]  = { { grade='Basico', chance=0.25 }, { grade='Intermedio', chance=0.25 }, { grade='Avanzado', chance=0.5 } },
    [10] = { { grade='Basico', chance=0.15 }, { grade='Intermedio', chance=0.20 }, { grade='Avanzado', chance=0.35 }, { grade='Especial', chance=0.30 } },
}

-- ── Puntos de recogida y destino por grado ────────────────────
-- Cada entrada tiene: pickup (punto A) y dropoff (punto B)
-- Podés cambiarlo a mano aquí o desde la tablet con "Poner aquí" / manual.
Config.MissionPoints = {
    Basico = {
        { pickup = vector4(-66.32, -1806.72, 26.5, 323.13), dropoff = vector4(-1644.06, -550.34, 32.61, 229.4) },
        { pickup = vector4(865.96, -2251.14, 29.5, 356.81), dropoff = vector4(182.64, -1012.63, 28.18, 227.76) },
        { pickup = vector4(238.99, 168.22, 104.09, 330.87), dropoff = vector4(2566.39, 328.85, 107.45, 357.62) },
        { pickup = vector4(-677.49, -241.02, 35.74, 132.12),dropoff = vector4(636.55, 287.99, 102.19, 145.44)  },
        { pickup = vector4(-960.53, -2904.91, 12.96, 60.85),dropoff = vector4(-411.92, -1830.97, 19.52, 208.63)},
    },
    Intermedio = {
        { pickup = vector4(-1709.57, -1091.07, 12.02, 66.86), dropoff = vector4(-1819.73, 762.98, 134.37, 225.1) },
        { pickup = vector4(1206.61, 2699.07, 36.95, 178.47),  dropoff = vector4(1661.54, 4847.22, 40.84, 289.45) },
        { pickup = vector4(1373.61, 3591.62, 33.9, 207.1),    dropoff = vector4(-1097.31, 2696.25, 18.33, 227.33)},
        { pickup = vector4(-3237.1, 968.36, 11.98, 276.08),   dropoff = vector4(-385.26, -104.03, 37.7, 116.86) },
        { pickup = vector4(253.8, -913.17, 27.86, 211.21),   dropoff = vector4(-473.05, 352.05, 103.11, 340.45) },
    },
    Avanzado = {
        { pickup = vector4(352.46, -1036.91, 28.91, 351.29), dropoff = vector4(299.06, -1082.88, 28.86, 179.37) },
        { pickup = vector4(352.46, -1036.91, 28.91, 351.29), dropoff = vector4(299.06, -1082.88, 28.86, 179.37) },
        { pickup = vector4(352.46, -1036.91, 28.91, 351.29), dropoff = vector4(299.06, -1082.88, 28.86, 179.37) },
        { pickup = vector4(352.46, -1036.91, 28.91, 351.29), dropoff = vector4(299.06, -1082.88, 28.86, 179.37) },
        { pickup = vector4(352.46, -1036.91, 28.91, 351.29), dropoff = vector4(299.06, -1082.88, 28.86, 179.37) },
    },
    Especial = {
        { pickup = vector4(924.89, -174.08, 73.51, 238.16),   dropoff = vector4(-1039.24, -2721.76, 12.61, 332.87) },
        { pickup = vector4(-1940.6, 267.57, 84.7, 109.62),    dropoff = vector4(2653.74, 3267.79, 54.24, 205.47)   },
        { pickup = vector4(1854.18, 3710.03, 32.27, 304.35),  dropoff = vector4(264.66, -1369.31, 31.03, 244.23)   },
        { pickup = vector4(-576.75, 5370.43, 69.25, 282.06),  dropoff = vector4(-530.2, -119.3, 37.82, 308.74)    },
        { pickup = vector4(315.73, -1376.68, 30.92, 39.15),   dropoff = vector4(1148.36, 2703.45, 37.08, 92.3)    },
    },
}

-- ── Peds disponibles por grado ────────────────────────────────
-- El sistema elige aleatoriamente uno de estos modelos al spawnear el NPC.
Config.MissionPeds = {
    Basico = {
        'a_f_m_bodybuild_01','a_f_m_beach_01','a_f_m_fatcult_01',
        'a_f_o_indian_01','a_f_y_bevhills_04','a_m_m_beach_02',
        'a_m_m_fatlatin_01','a_m_m_hasjew_01','a_m_m_soucent_03',
        'a_m_m_tennis_01','a_m_m_tranvest_01','a_m_y_breakdance_01',
        'a_m_y_gay_01','a_m_y_gay_02','a_m_y_musclbeac_01',
        'a_m_y_soucent_01','a_m_y_runner_01','a_m_y_smartcaspat_01',
    },
    Intermedio = {
        'a_f_y_bevhills_04','a_m_m_tennis_01','a_m_y_smartcaspat_01',
        'a_m_m_hasjew_01','a_f_o_indian_01','a_m_m_tranvest_01',
    },
    Avanzado = {
        'a_m_m_business_01','a_f_y_business_01',
        'a_f_y_business_02','a_m_y_business_02',
        'g_m_y_lost_01','g_m_y_lost_02','g_m_y_lost_03',
    },
    Especial = {
        's_m_y_swat_01','a_m_m_skidrow_01',
        'g_m_y_mexgang_01','g_m_y_ballaorig_01','g_m_y_famdnf_01',
        'g_m_y_famfor_01','g_m_y_famca_01',
    },
}

-- ── Parámetros de la barra de Stress ─────────────────────────
-- speedThresholdKmh → velocidad a partir de la cual sube el stress
-- 120 km/h ≈ 74.5 mph
Config.StressBars = {
    speedThresholdKmh = 80,    -- km/h → internamente se convierte a m/s
    stressRiseRate    = 2.5,    -- % por segundo que sube cuando supera el umbral
    stressFallRate    = 0.4,    -- % por segundo que baja cuando está bajo el umbral
    stressMaxLock     = true,   -- true = al llegar al 100% queda bloqueada hasta fin de misión
    impactThreshold   = 15,     -- puntos mínimos de daño (body o motor) para contar como impacto (rango 5-50)
    scaredRiseRate    = 25.0,   -- % de subida instantánea por cada impacto detectado
    scaredFallRate    = 0.2,    -- % por segundo que baja la barra de "asustado"
    -- Penalizaciones al finalizar el viaje:
    penaltyScared     = 25,     -- % de reducción del pago si "asustado" llega al 100%
    penaltyStress     = 25,     -- % de reducción adicional si "stress" llega al 100%
}

-- ── Pago base de misiones NPC ─────────────────────────────────
-- El pago real se calcula:
--   basePay    = NpcMissionBasePay × baseMultiplier × payMultiplier
--   extraDist  = math.floor(metrosRecorridos / NpcTripUnitMeters) × NpcTripPerUnit
--   finalPay   = (basePay + extraDist) × penalizaciones × bonus_tiempo
--
-- Ajustá NpcTripPerUnit y NpcTripUnitMeters para controlar cuánto
-- sube el precio por distancia en las misiones NPC, sin afectar
-- los viajes de jugadores (que usan Config.TripDefaults).
Config.NpcMissionBasePay  = 20   -- pago base antes de multiplicadores
Config.NpcMissionBaseXp   = 20   -- XP base por completar una misión NPC (se multiplica por baseMultiplier del grado)

Config.NpcTripPerUnit     = 5    -- $ que se suman por cada "unidad" de distancia recorrida
                                  -- (recomendado: 5-15 para economía balanceada)
Config.NpcTripUnitMeters  = 100  -- cada cuántos metros se cobra una unidad
                                  -- (recomendado: 80-150; cuanto mayor, menos sube el precio)

-- ═══════════════════════════════════════════════════════════════
--  DROP DE ITEMS — Misiones Avanzadas (persecución)
--
--  Cuando el jugador atrapa al NPC hay una probabilidad de que
--  caiga un ítem al inventario. Funciona en DOS pasos:
--
--  1) dropChance  → probabilidad general de que caiga ALGÚN item
--                   (0.0 = nunca, 1.0 = siempre, 0.10 = 10%)
--
--  2) items[]     → lista de ítems posibles. Cada uno tiene:
--       item    → nombre del item en el inventario (string)
--       label   → nombre legible para mostrar en notificación
--       chance  → probabilidad relativa dentro de la lista
--                 (no necesita sumar 1.0 — el sistema normaliza)
--       amount  → cantidad que recibe el jugador (default 1)
--
--  Ejemplo: dropChance=0.10 → 10% de que caiga algo.
--           Si cae, se elige entre los items según su chance.
-- ═══════════════════════════════════════════════════════════════
Config.ChaseItemDrop = {
    dropChance = 0.90,  -- 90% de probabilidad de que caiga algún item

    items = {
        { item='weapon_pistol', label='Pistola',       chance=0.3, amount=1 },
        { item='radio',         label='Radio',         chance=0.3, amount=1 },
        { item='phone',         label='Teléfono',      chance=0.3, amount=1 },
        -- Podés agregar más items aquí:
        -- { item='lockpick',   label='Ganzúa',        chance=0.1, amount=1 },
        -- { item='money_bag',  label='Bolsa de plata', chance=0.05, amount=1 },
    },
}
-- ═══════════════════════════════════════════════════════════════

-- ═══════════════════════════════════════════════════════════════
--  ROPA DE TRABAJO TAXI
--  Aplicada con /taxiropa o desde el punto Vestuario de la tablet.
--  component → SetPedComponentVariation(ped, component, drawable, texture, 0)
--  prop      → SetPedPropIndex(ped, prop, drawable, texture, true)
--  drawable = -1 en un prop → lo elimina (ClearPedProp)
-- ═══════════════════════════════════════════════════════════════
Config.RopaTrabajo = {
    male = {
        ['torso2']    = { component = 11, drawable = 89, texture = 0  },
        ['t-shirt']   = { component = 8,  drawable = 15,  texture = 0  },
        ['arms']      = { component = 3,  drawable = 30,  texture = 0  },
        ['pants']     = { component = 4,  drawable = 144, texture = 19 },
        ['shoes']     = { component = 6,  drawable = 7,   texture = 7 },
        ['accessory'] = { component = 7,  drawable = 0,   texture = 0  },
        ['decals']    = { component = 10, drawable = 0,   texture = 0  },
        ['torso']     = { component = 9,  drawable = 0,   texture = 0  },
        ['mask']      = { component = 1,  drawable = 0,   texture = 0  },
        ['bag']       = { component = 5,  drawable = 0,   texture = 0  },
        ['hat']       = { prop = 0,       drawable = 143, texture = 5  },
    },
    female = {
        ['torso2']    = { component = 11, drawable = 245, texture = 7  },
        ['t-shirt']   = { component = 8,  drawable = 15,  texture = 0  },
        ['arms']      = { component = 3,  drawable = 44,  texture = 0  },
        ['pants']     = { component = 4,  drawable = 27,  texture = 2  },
        ['shoes']     = { component = 6,  drawable = 1,   texture = 4  },
        ['accessory'] = { component = 7,  drawable = 0,   texture = 0  },
        ['decals']    = { component = 10, drawable = 0,   texture = 0  },
        ['torso']     = { component = 9,  drawable = 0,   texture = 0  },
        ['mask']      = { component = 1,  drawable = -1,  texture = 0  },
        ['bag']       = { component = 5,  drawable = 0,   texture = 0  },
        ['hat']       = { prop = 0,       drawable = 129, texture = 2  },
    },
}

-- ═══════════════════════════════════════════════════════════════
--  FAQ — Contenido del panel informativo de la Tablet
--  ⚠ Este bloque es de REFERENCIA. El contenido que se muestra
--  en la tablet se edita directamente en html/script_faq dentro
--  del index.html (variable FAQ_DATA al final del archivo).
--  Mantené este bloque sincronizado si querés control desde Lua.
-- ═══════════════════════════════════════════════════════════════
Config.Faq = {
    guideTitle    = 'Guía de uso para la Tablet de la Empresa',
    guideSubtitle = 'Información interna. Solo lectura.',

    -- sections = {
    --     { icon='taxi',        title='Inicio de Servicio',
    --       items={
    --         { q='¿Cómo empiezo a trabajar?',    a='Presioná "Iniciar Servicio" en el menú lateral.' },
    --         { q='¿Dónde spawneo mi vehículo?',  a='Garage marcado en el mapa → panel de Vehículos.' },
    --       }
    --     },
    --     { icon='route',       title='Viajes',
    --       items={
    --         { q='¿Cómo acepto un viaje?',        a='Notificación en pantalla → Aceptar o Ignorar.' },
    --         { q='¿Cómo finalizo un viaje?',      a='Llegá al destino → botón Finalizar en el dashboard.' },
    --         { q='¿Qué pasa si cancelo?',         a='Cancelaciones frecuentes afectan tu reputación.' },
    --       }
    --     },
    --     { icon='dollar-sign', title='Salarios y Propinas',
    --       items={
    --         { q='¿Cuándo cobro el salario?',    a='Automáticamente en intervalos mientras estés en servicio.' },
    --         { q='¿Qué son las propinas?',       a='El pasajero puede dejarte propina al finalizar el viaje.' },
    --       }
    --     },
    --     { icon='star',        title='Niveles y XP',
    --       items={
    --         { q='¿Cómo subo de nivel?',          a='Completando viajes. Al acumular XP subís automáticamente.' },
    --         { q='¿Para qué sirven los niveles?', a='Desbloquean vehículos de mayor gama y misiones exclusivas.' },
    --       }
    --     },
    --     { icon='shield-alt',  title='Rango y Permisos',
    --       items={
    --         { q='¿Quién gestiona empleados?',   a='Supervisor, Sub-Jefe y Jefe.' },
    --         { q='¿Cómo me ascienden?',          a='Un superior lo hace desde el panel de Empleados.' },
    --       }
    --     },
    -- },

    -- Comandos visibles en la tablet (sin descripción)
    commands = {
        '/dartaxijob + id',
        '/sacartaxijob + id',
        '/taxijob',
        '/calltaxi',
        '/taxiropa',
    },
}

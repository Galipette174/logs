--========================================
-- logsgali - GALI (server.lua) FINAL
-- (Panel suspect + TP/Bring/Freeze/Spectate + Suspect system strict)
--========================================

local SCRIPT_NAME = 'logsgali'
local SCRIPT_VERSION = '1.0.0'
local LOGGER_PREFIX = '^5[logsgali | Galipette]^7'

--========================
-- Banner
--========================
local function PrintBanner()
    print('^5====================================^7')
    print('^5               G A L I              ^7')
    print('^5            logsgali script         ^7')
    print(('^5           Version: %s           ^7'):format(SCRIPT_VERSION))
    print('^5           Made by Gali             ^7')
    print('^5====================================^7')
end

CreateThread(function()
    Wait(250)
    PrintBanner()
end)

local function now()
    return os.date('%d/%m/%Y %H:%M:%S')
end

--========================
-- File logs
--========================
local function appendToFile(line)
    local res = GetCurrentResourceName()
    local current = LoadResourceFile(res, Config.LogFile) or ''
    SaveResourceFile(res, Config.LogFile, current .. line .. '\n', -1)
end

--========================
-- Discord helpers
--========================
local function discordNumericId(discordIdentifier)
    if not discordIdentifier then return nil end
    return discordIdentifier:gsub('discord:', '')
end

local function discordProfileUrl(discordIdentifier)
    local id = discordNumericId(discordIdentifier)
    if not id or id == '' then return nil end
    return 'https://discord.com/users/' .. id
end

local function profileButton(discordIdentifier, label)
    local url = discordProfileUrl(discordIdentifier)
    if not url then return nil end

    return {
        type = 1,
        components = {{
            type = 2,
            style = 5,
            label = label or 'Profil Discord',
            url = url
        }}
    }
end

local function discordText(discordIdentifier)
    local id = discordNumericId(discordIdentifier)
    if not id or id == '' then return 'N/A' end
    return ('<@%s> (`%s`)'):format(id, id)
end

local function sendDiscord(webhook, title, fields, color, components)
    if not webhook or webhook == '' then return end

    local payload = {
        username = Config.BotName or 'Galipette Logs',
        embeds = {{
            title = title,
            color = color or 3447003,
            fields = fields or {},
            footer = { text = now() }
        }},
        components = components
    }

    PerformHttpRequest(webhook, function() end, 'POST', json.encode(payload), {
        ['Content-Type'] = 'application/json'
    })
end

--========================
-- Identifiants
--========================
local function getIdByPrefix(src, prefix)
    for _, id in pairs(GetPlayerIdentifiers(src)) do
        if id:sub(1, #prefix) == prefix then return id end
    end
    return nil
end

local function getPlayerIds(src)
    return {
        license  = getIdByPrefix(src, 'license:'),
        license2 = getIdByPrefix(src, 'license2:'),
        steam    = getIdByPrefix(src, 'steam:'),
        discord  = getIdByPrefix(src, 'discord:'),
    }
end

local function safeToken(token)
    if not token or token == '' then return nil end
    if #token <= 12 then return token end
    return token:sub(1, 6) .. '...' .. token:sub(-6)
end

local function getTokenPreview(src)
    local tokens = {}
    local count = 0

    if GetNumPlayerTokens then
        count = GetNumPlayerTokens(src) or 0
        for i = 0, math.min(count - 1, 1) do
            local tk = GetPlayerToken(src, i)
            if tk then tokens[#tokens + 1] = safeToken(tk) end
        end
    end

    if count <= 0 then return '`0`' end
    if #tokens == 0 then return ('`%d`'):format(count) end
    return ('`%d` (%s)'):format(count, table.concat(tokens, ', '))
end

local function idsToText(ids, src)
    local lines = {}
    lines[#lines + 1] = ('License: `%s`'):format(ids.license or 'N/A')
    if ids.license2 then lines[#lines + 1] = ('License2: `%s`'):format(ids.license2) end
    lines[#lines + 1] = ('Steam: `%s`'):format(ids.steam or 'Non lié')
    lines[#lines + 1] = ('Discord: %s'):format(discordText(ids.discord))
    if src then lines[#lines + 1] = ('Tokens: %s'):format(getTokenPreview(src)) end
    return table.concat(lines, '\n')
end

--========================
-- Logger central
--========================
local function Log(category, title, fields, data, color, webhookKey, components)
    if Config.EnableConsole then
        print(('%s [%s] %s'):format(LOGGER_PREFIX, category, title))
        if data then
            print(('%s %s'):format(LOGGER_PREFIX, json.encode(data)))
        end
    end

    if Config.EnableFile then
        appendToFile(('[%s] [%s] %s'):format(now(), category, title))
        if data then appendToFile(json.encode(data)) end
    end

    local webhook = Config.Webhooks and Config.Webhooks[webhookKey]
    sendDiscord(webhook, title, fields, color, components)
end

exports('Log', Log)

--=====================================================
-- OPTION A : SUSPICION SCORE + ALERTS (STRICT)
--=====================================================
local Suspicion = {
    file = 'suspicion.json',
    threshold = 70,
    maxScore = 100,
    decayPerMinute = 1,
    alertCooldownMs = 5 * 60 * 1000,

    bigMoneyThreshold = 500000,     -- ✅ 500k
    crashAfterSeconds = 10,         -- ✅ crash < 10s après transfert suspect
    killWindowSeconds = 300,        -- ✅ 5 min
    killThreshold = 5,              -- ✅ >5 kills/5min
}

local suspicionData = {}
local lastAlert = {} -- key -> GetGameTimer()

-- track
local lastSuspiciousTransfer = {}  -- src -> {t=GetGameTimer(), reason=..., item=..., count=..., toType=..., toInv=...}
local killTracker = {}            -- killerKey -> {times={...}, total=...}
local dupeTracker = {}            -- src -> { last=GetGameTimer(), n=..., item=..., count=... }

local function clamp(n, a, b)
    if n < a then return a end
    if n > b then return b end
    return n
end

local function loadSuspicion()
    local res = GetCurrentResourceName()
    local raw = LoadResourceFile(res, Suspicion.file)
    if raw and raw ~= '' then
        local ok, decoded = pcall(json.decode, raw)
        if ok and type(decoded) == 'table' then
            suspicionData = decoded
            return
        end
    end
    suspicionData = {}
end

local function saveSuspicion()
    local res = GetCurrentResourceName()
    SaveResourceFile(res, Suspicion.file, json.encode(suspicionData, { indent = true }), -1)
end

local function getPlayerKey(src)
    local ids = getPlayerIds(src)
    if ids.license and ids.license ~= '' then return ids.license end
    return ids.discord or ids.steam or ('src:' .. tostring(src))
end

-- ✅ affiche aussi le check en console + webhook alerts (même si score < threshold)
local function logSuspicionCheck(src, points, reason, extra, newScore)
    local ids = getPlayerIds(src)
    local name = GetPlayerName(src) or ('ID %s'):format(src)
    local btn = profileButton(ids.discord, 'Profil Discord (suspect)')
    local components = btn and { btn } or nil

    Log('Alerte', ('🧠 Suspect Check: %s (+%d)'):format(reason or 'N/A', points or 0), {
        { name = 'Joueur', value = ('`%s` (`%d`)'):format(name, src), inline = false },
        { name = 'IDs', value = idsToText(ids, src), inline = false },
        { name = 'Points', value = ('`+%d`'):format(points or 0), inline = true },
        { name = 'Score', value = ('`%d/%d`'):format(newScore or 0, Suspicion.maxScore), inline = true },
        { name = 'Détails', value = ('```json\n%s\n```'):format(json.encode(extra or {})), inline = false },
    }, { src = src, points = points, reason = reason, extra = extra, score = newScore }, 15105570, 'alerts', components)
end

local function addSuspicion(src, points, reason, extra)
    if not src then return end

    local key = getPlayerKey(src)
    local name = GetPlayerName(src) or ('ID %s'):format(src)
    local ids = getPlayerIds(src)

    local entry = suspicionData[key]
    if not entry then
        entry = { score = 0, lastUpdate = os.time(), history = {} }
        suspicionData[key] = entry
    end

    -- decay
    local nowTs = os.time()
    local diff = nowTs - (entry.lastUpdate or nowTs)
    if diff > 0 then
        local minutes = math.floor(diff / 60)
        if minutes > 0 then
            entry.score = clamp((entry.score or 0) - (minutes * Suspicion.decayPerMinute), 0, Suspicion.maxScore)
        end
    end

    entry.lastUpdate = nowTs
    entry.score = clamp((entry.score or 0) + (points or 0), 0, Suspicion.maxScore)

    entry.history[#entry.history + 1] = {
        t = now(),
        points = points,
        reason = reason,
        extra = extra
    }
    if #entry.history > 40 then table.remove(entry.history, 1) end

    saveSuspicion()

    -- ✅ TOUS les checks -> console + webhook alerts
    logSuspicionCheck(src, points, reason, extra, entry.score)

    -- alert "threshold" (cooldown) si configuré
    if not (Config.Webhooks and Config.Webhooks.alerts and Config.Webhooks.alerts ~= '') then
        return
    end

    local timerNow = GetGameTimer()
    local last = lastAlert[key] or 0
    if entry.score >= Suspicion.threshold and (timerNow - last) >= Suspicion.alertCooldownMs then
        lastAlert[key] = timerNow

        local btn = profileButton(ids.discord, 'Profil Discord (suspect)')
        local components = btn and { btn } or nil

        Log('Alerte', '🚨 ALERTE SUSPICION (SEUIL)', {
            { name = 'Joueur', value = ('`%s` (`%d`)'):format(name, src), inline = false },
            { name = 'IDs', value = idsToText(ids, src), inline = false },
            { name = 'Score', value = ('`%d/%d`'):format(entry.score, Suspicion.maxScore), inline = true },
            { name = 'Dernier trigger', value = ('`%s` (+%d)'):format(reason or 'N/A', points or 0), inline = true },
        }, { key = key, score = entry.score, last = entry.history[#entry.history] }, 15158332, 'alerts', components)
    end
end

-- decay loop
CreateThread(function()
    loadSuspicion()
    while true do
        Wait(120000)
        local changed = false
        local nowTs = os.time()
        for _, entry in pairs(suspicionData) do
            local diff = nowTs - (entry.lastUpdate or nowTs)
            local minutes = math.floor(diff / 60)
            if minutes > 0 and (entry.score or 0) > 0 then
                entry.score = clamp((entry.score or 0) - (minutes * Suspicion.decayPerMinute), 0, Suspicion.maxScore)
                entry.lastUpdate = nowTs
                changed = true
            end
        end
        if changed then saveSuspicion() end
    end
end)

--========================
-- Weapon mapping (hash -> WEAPON_*)
--========================
local WeaponHashToItem = {}

local function buildWeaponHashMap()
    if GetResourceState('ox_inventory') ~= 'started' then return end
    local items = exports.ox_inventory:Items()
    for name, _ in pairs(items) do
        if type(name) == 'string' and name:sub(1, 7) == 'WEAPON_' then
            WeaponHashToItem[GetHashKey(name)] = name
        end
    end
end

CreateThread(function()
    Wait(500)
    buildWeaponHashMap()
end)

AddEventHandler('onResourceStart', function(res)
    if res == 'ox_inventory' then
        Wait(500)
        buildWeaponHashMap()
    end
end)

--========================
-- Connexion / Déconnexion
--========================
AddEventHandler('playerConnecting', function(name)
    local src = source
    local ids = getPlayerIds(src)

    local btn = profileButton(ids.discord, 'Profil Discord (joueur)')
    local components = btn and { btn } or nil

    Log('Connexion', '✅ Connexion', {
        { name = 'Pseudo', value = ('`%s`'):format(name), inline = false },
        { name = 'IDs', value = idsToText(ids, src), inline = false },
    }, { source = src, ids = ids }, 3066993, 'connect', components)
end)

AddEventHandler('playerDropped', function(reason)
    local src = source

    -- ✅ Crash après transfert suspect
    local last = lastSuspiciousTransfer[src]
    if last then
        local dt = (GetGameTimer() - last.t) / 1000.0
        if dt <= Suspicion.crashAfterSeconds then
            addSuspicion(src, 35, 'Crash après transfert suspect', {
                seconds = dt,
                lastTransfer = last,
                dropReason = reason
            })
        end
        lastSuspiciousTransfer[src] = nil
    end

    local name = GetPlayerName(src) or ('ID %s'):format(src)
    local ids = getPlayerIds(src)

    local btn = profileButton(ids.discord, 'Profil Discord (joueur)')
    local components = btn and { btn } or nil

    Log('Déconnexion', '⚠️ Déconnexion', {
        { name = 'Pseudo', value = ('`%s`'):format(name), inline = false },
        { name = 'IDs', value = idsToText(ids, src), inline = false },
        { name = 'Raison', value = ('`%s`'):format(reason or 'unknown'), inline = false },
    }, { source = src, ids = ids, reason = reason }, 8421504, 'disconnect', components)

    -- clean
    dupeTracker[src] = nil
end)

--========================
-- Tir (anti-spam)
--========================
local lastShot = {}

RegisterNetEvent('ox_logs:shot', function(weaponData)
    local src = source
    local t = GetGameTimer()

    local cd = tonumber(Config.ShootCooldown) or 300
    if lastShot[src] and (t - lastShot[src]) < cd then return end
    lastShot[src] = t

    local name = GetPlayerName(src) or ('ID %s'):format(src)
    local ids = getPlayerIds(src)

    local btn = profileButton(ids.discord, 'Profil Discord (joueur)')
    local components = btn and { btn } or nil

    local itemName, hash = nil, nil
    if type(weaponData) == 'table' then
        itemName = weaponData.weaponItem
        hash = weaponData.weaponHash
    end
    if not itemName and hash then itemName = WeaponHashToItem[hash] end
    itemName = itemName or 'WEAPON_UNKNOWN'

    Log('Combat', '🔫 Tir', {
        { name = 'Pseudo', value = ('`%s`'):format(name), inline = false },
        { name = 'IDs', value = idsToText(ids, src), inline = false },
        { name = 'Arme (item)', value = ('`%s`'):format(itemName), inline = false },
    }, { source = src, ids = ids, weapon = weaponData }, 3447003, 'shot', components)
end)

--========================
-- KILL TRACKER (joueurs)
--========================
local function pushKill(killerSrc)
    if not killerSrc then return end
    if GetPlayerName(killerSrc) == nil then return end

    local key = getPlayerKey(killerSrc)
    killTracker[key] = killTracker[key] or { times = {}, total = 0 }

    local t = os.time()
    local tr = killTracker[key]
    tr.total = (tr.total or 0) + 1

    tr.times[#tr.times + 1] = t

    -- clean window 5 min
    local window = Suspicion.killWindowSeconds
    while #tr.times > 0 and (t - tr.times[1]) > window do
        table.remove(tr.times, 1)
    end

    -- ✅ condition : +5 kills en 5 min (strict)
    if #tr.times > Suspicion.killThreshold then
        addSuspicion(killerSrc, 25, 'Kill spam (>5 kills / 5 min)', {
            killsInWindow = #tr.times,
            windowSeconds = window
        })
    end

    -- ✅ condition : kill total trop haut (streak globale)
    if tr.total >= 50 and (tr.total % 10 == 0) then
        addSuspicion(killerSrc, 15, 'Kill total élevé (streak)', { totalKills = tr.total })
    end
end

--========================
-- Mort (joueurs)
--========================
RegisterNetEvent('ox_logs:died', function(info)
    local src = source
    local vName = GetPlayerName(src) or ('ID %s'):format(src)
    local vIds = getPlayerIds(src)

    local killerValue = '`N/A`'
    local killerDiscordIdentifier = nil

    if info and info.killerServerId then
        local ksrc = tonumber(info.killerServerId)
        if ksrc then
            local kName = GetPlayerName(ksrc) or ('ID %s'):format(ksrc)
            local kIds = getPlayerIds(ksrc)
            killerDiscordIdentifier = kIds.discord
            killerValue = ('`%s`\n%s'):format(kName, idsToText(kIds, ksrc))

            -- ✅ track kill (joueur)
            pushKill(ksrc)
        end
    end

    local weaponText = 'unknown'
    if info and info.weaponHash then
        weaponText = WeaponHashToItem[info.weaponHash] or tostring(info.weaponHash)
    end
    local dmgTypeText = (info and (info.damageTypeLabel or tostring(info.damageType))) or 'unknown'

    local components = {}
    local vBtn = profileButton(vIds.discord, 'Profil Victime')
    if vBtn then components[#components + 1] = vBtn end
    local kBtn = profileButton(killerDiscordIdentifier, 'Profil Killer')
    if kBtn then components[#components + 1] = kBtn end
    if #components == 0 then components = nil end

    Log('Combat', '💀 Mort', {
        { name = 'Victime', value = ('`%s`\n%s'):format(vName, idsToText(vIds, src)), inline = false },
        { name = 'Killer', value = killerValue, inline = false },
        { name = 'Raison', value = ('`%s`'):format(dmgTypeText), inline = true },
        { name = 'Cause / Arme (item)', value = ('`%s`'):format(weaponText), inline = true },
    }, { source = src, victim = { name = vName, ids = vIds }, info = info }, 15158332, 'death', components)
end)

--========================
-- Inventaire (ox_inventory) : logs + suspicion STRICT
--========================
local HEAVY_WEAPONS = {
    WEAPON_RPG = true,
    WEAPON_HOMINGLAUNCHER = true,
    WEAPON_GRENADELAUNCHER = true,
    WEAPON_GRENADELAUNCHER_SMOKE = true,
    WEAPON_MINIGUN = true,
    WEAPON_RAILGUN = true,
    WEAPON_RAILGUNXM3 = true,
    WEAPON_COMPACTLAUNCHER = true,
}

local function isSpecialWeapon(itemName)
    if type(itemName) ~= 'string' then return false end
    if itemName:sub(1, 7) ~= 'WEAPON_' then return false end
    if itemName:find('MK2') then return true end
    if HEAVY_WEAPONS[itemName] then return true end
    return false
end

local CASH_ITEMS = { money = true, cash = true, black_money = true, dirty_money = true }

CreateThread(function()
    local tries = 0
    while GetResourceState('ox_inventory') ~= 'started' and tries < 40 do
        Wait(250)
        tries = 1
    end

    if GetResourceState('ox_inventory') ~= 'started' then
        Log('Erreur', 'ox_inventory', {
            { name = 'Info', value = '`ox_inventory n’est pas démarré, hooks désactivés`', inline = false }
        }, nil, 15158332, 'transfer_inventory')
        return
    end

    local function pickWebhook(fromType, toType)
        if toType == 'drop' then return 'drop' end
        if fromType == 'drop' then return 'pickup' end
        if fromType == 'player' and toType == 'player' then return 'transfer_player' end
        if fromType == 'trunk' or toType == 'trunk' or fromType == 'glovebox' or toType == 'glovebox' then
            return 'transfer_vehicle'
        end
        return 'transfer_inventory'
    end

    local function invText(invType, invId)
        invType = invType or 'unknown'
        invId = tostring(invId)

        if invType == 'player' then
            local pid = tonumber(invId)
            if pid then
                return ("Joueur **%s** (`%d`)"):format(GetPlayerName(pid) or 'N/A', pid)
            end
            return ("Joueur `%s`"):format(invId)
        end

        if invType == 'trunk' then return ("Coffre `%s`"):format(invId) end
        if invType == 'glovebox' then return ("Boîte à gants `%s`"):format(invId) end
        if invType == 'stash' then return ("Stash `%s`"):format(invId) end
        if invType == 'drop' then return ("Drop `%s`"):format(invId) end
        if invType == 'shop' then return ("Shop `%s`"):format(invId) end
        if invType == 'crafting' then return ("Craft `%s`"):format(invId) end

        return ("%s `%s`"):format(invType, invId)
    end

    exports.ox_inventory:registerHook('swapItems', function(payload)
        if type(payload) ~= 'table' then return end
        if not payload.source then return end

        local src = payload.source
        local name = GetPlayerName(src) or ('ID %s'):format(src)
        local ids = getPlayerIds(src)

        local btn = profileButton(ids.discord, 'Profil Discord (joueur)')
        local components = btn and { btn } or nil

        local action = payload.action or 'move'
        local webhookKey = pickWebhook(payload.fromType, payload.toType)

        -- ignore move interne
        local sameInv = (payload.fromType == payload.toType)
            and (tostring(payload.fromInventory) == tostring(payload.toInventory))
        if sameInv and action ~= 'give' then
            return
        end

        local itemLabel = payload.fromSlot and (payload.fromSlot.label or payload.fromSlot.name) or 'unknown'
        local itemName = payload.fromSlot and (payload.fromSlot.name or '') or ''
        local count = tonumber(payload.count) or 0

        local fromTxt = invText(payload.fromType, payload.fromInventory)
        local toTxt = invText(payload.toType, payload.toInventory)

        local title, color = "📦 Transfert d'item", 3447003
        if webhookKey == 'drop' then title, color = "📦 Drop", 15844367
        elseif webhookKey == 'pickup' then title, color = "📥 Pickup", 5763719
        elseif webhookKey == 'transfer_player' then title, color = "🤝 Transfert joueur", 3066993
        elseif webhookKey == 'transfer_vehicle' then title, color = "🚗 Transfert véhicule", 15105570
        else title, color = "📦 Transfert inventaire", 3447003 end

        -- ✅ log inventaire normal
        Log('Inventaire', title, {
            { name = 'Pseudo', value = ('`%s`'):format(name), inline = false },
            { name = 'IDs', value = idsToText(ids, src), inline = false },
            { name = 'Action', value = ('`%s`'):format(action), inline = true },
            { name = 'Item', value = ('`%s x%d`'):format(itemLabel, count), inline = true },
            { name = 'De', value = fromTxt, inline = false },
            { name = 'Vers', value = toTxt, inline = false },
        }, payload, color, webhookKey, components)

        --=========================================================
        -- ✅ SUSPICION STRICT: uniquement règles demandées
        --=========================================================

        -- 1) grosse somme d'un coup >= 500k
        if CASH_ITEMS[itemName] and count >= Suspicion.bigMoneyThreshold then
            addSuspicion(src, 35, 'Grosse somme reçue (>=500k)', {
                item = itemName, count = count, fromType = payload.fromType, toType = payload.toType,
                fromInv = payload.fromInventory, toInv = payload.toInventory
            })

            lastSuspiciousTransfer[src] = {
                t = GetGameTimer(),
                reason = 'Grosse somme (>=500k)',
                item = itemName,
                count = count,
                toType = payload.toType,
                toInv = payload.toInventory
            }
            return
        end

        -- 2) réception d'arme spéciale (mk2/heavy) uniquement si le joueur la reçoit
        local receiving = (payload.toType == 'player' and tonumber(payload.toInventory) == src)
        if receiving and isSpecialWeapon(itemName) then
            addSuspicion(src, 30, 'Réception arme spéciale (MK2/Heavy)', {
                item = itemName, count = count, fromType = payload.fromType, fromInv = payload.fromInventory
            })

            lastSuspiciousTransfer[src] = {
                t = GetGameTimer(),
                reason = 'Réception arme spéciale',
                item = itemName,
                count = count,
                toType = payload.toType,
                toInv = payload.toInventory
            }
            return
        end

        -- 3) duplication (heuristique) : même item reçu très vite depuis inv non-player/non-drop
        if receiving and payload.fromType ~= 'player' and payload.fromType ~= 'drop' then
            local st = dupeTracker[src]
            local nowT = GetGameTimer()
            if not st then
                dupeTracker[src] = { last = nowT, n = 1, item = itemName, count = count }
            else
                local dt = nowT - (st.last or nowT)
                if dt <= 1500 and st.item == itemName and count > 0 then
                    st.n = (st.n or 1) + 1
                    st.last = nowT
                    st.count = (st.count or 0) + count

                    if st.n >= 4 then
                        addSuspicion(src, 40, 'Duplication suspecte (spam ajout item)', {
                            item = itemName, hits = st.n, totalCount = st.count,
                            fromType = payload.fromType, fromInv = payload.fromInventory
                        })

                        lastSuspiciousTransfer[src] = {
                            t = GetGameTimer(),
                            reason = 'Duplication suspecte',
                            item = itemName,
                            count = st.count,
                            toType = payload.toType,
                            toInv = payload.toInventory
                        }

                        dupeTracker[src] = nil
                    end
                else
                    dupeTracker[src] = { last = nowT, n = 1, item = itemName, count = count }
                end
            end
        end
    end, { print = false })

    print(('%s ^2Hook ox_inventory swapItems chargé^7 (logs + suspicion strict).'):format(LOGGER_PREFIX))
end)

--=====================================================
-- COMMANDES STAFF (toutes -> console + webhook alerts)
--=====================================================
local function formatHistory(entry, maxLines)
    if not entry or type(entry.history) ~= 'table' or #entry.history == 0 then
        return '`Aucun historique`'
    end

    local max = maxLines or 10
    local lines = {}
    local start = math.max(1, #entry.history - max + 1)
    for i = start, #entry.history do
        local h = entry.history[i]
        lines[#lines + 1] = ('- [%s] +%s : %s'):format(h.t or '?', tostring(h.points or 0), tostring(h.reason or 'N/A'))
    end
    return table.concat(lines, '\n')
end

local function staffAllowed(src, ace)
    if src == 0 then return true end
    return IsPlayerAceAllowed(src, ace)
end

local function staffName(src)
    if src == 0 then return 'CONSOLE' end
    return GetPlayerName(src) or ('ID %d'):format(src)
end

local function staffLogCheck(title, fields, data)
    Log('Staff', title, fields, data, 3447003, 'alerts', nil)
end

-- /suspect <id>
RegisterCommand('suspect', function(src, args)
    if not staffAllowed(src, 'logsgali.suspect') then
        if src ~= 0 then TriggerClientEvent('chat:addMessage', src, { args = { '^1Accès refusé', "Permission requise." } }) end
        return
    end

    local target = tonumber(args[1] or '')
    if not target then
        local msg = 'Usage: suspect <serverId>'
        print(msg)
        if src ~= 0 then TriggerClientEvent('chat:addMessage', src, { args = { '^1Usage', '/suspect <serverId>' } }) end
        return
    end

    if GetPlayerName(target) == nil then
        local msg = ('Joueur introuvable: %s'):format(target)
        print(msg)
        if src ~= 0 then TriggerClientEvent('chat:addMessage', src, { args = { '^1Erreur', msg } }) end
        return
    end

    local key = getPlayerKey(target)
    local entry = suspicionData[key]
    local ids = getPlayerIds(target)
    local tName = GetPlayerName(target) or ('ID %d'):format(target)

    local score = entry and (entry.score or 0) or 0
    local hist = entry and formatHistory(entry, 10) or '`Aucun historique`'

    print(('[SUSPECT CHECK] Staff=%s | Target=%s(%d) | Score=%d/%d'):format(staffName(src), tName, target, score, Suspicion.maxScore))
    print(idsToText(ids, target))
    print(hist)

    staffLogCheck('🔎 Check suspicion', {
        { name = 'Staff', value = ('`%s` (`%d`)'):format(staffName(src), src), inline = false },
        { name = 'Cible', value = ('`%s` (`%d`)'):format(tName, target), inline = false },
        { name = 'Score', value = ('`%d/%d`'):format(score, Suspicion.maxScore), inline = true },
        { name = 'IDs', value = idsToText(ids, target), inline = false },
        { name = 'Derniers triggers', value = hist, inline = false },
    }, { staff = src, target = target, key = key, score = score })

    if src ~= 0 then
        TriggerClientEvent('chat:addMessage', src, {
            args = { '^3Suspect', ('%s (%d) | Score %d/%d\nDerniers triggers:\n%s'):format(tName, target, score, Suspicion.maxScore, hist) }
        })
    end
end, false)

-- /resetsuspect <id>
RegisterCommand('resetsuspect', function(src, args)
    if not staffAllowed(src, 'logsgali.resetsuspect') then
        if src ~= 0 then TriggerClientEvent('chat:addMessage', src, { args = { '^1Accès refusé', "Permission requise." } }) end
        return
    end

    local target = tonumber(args[1] or '')
    if not target then
        local msg = 'Usage: resetsuspect <serverId>'
        print(msg)
        if src ~= 0 then TriggerClientEvent('chat:addMessage', src, { args = { '^1Usage', '/resetsuspect <serverId>' } }) end
        return
    end

    if GetPlayerName(target) == nil then
        local msg = ('Joueur introuvable: %s'):format(target)
        print(msg)
        if src ~= 0 then TriggerClientEvent('chat:addMessage', src, { args = { '^1Erreur', msg } }) end
        return
    end

    local key = getPlayerKey(target)
    local entry = suspicionData[key]
    local ids = getPlayerIds(target)
    local tName = GetPlayerName(target) or ('ID %d'):format(target)

    if not entry then
        local msg = ('Aucune donnée suspicion à reset pour %s (%d)'):format(tName, target)
        print(msg)
        if src ~= 0 then TriggerClientEvent('chat:addMessage', src, { args = { '^3ResetSuspect', msg } }) end
        return
    end

    local oldScore = entry.score or 0
    entry.score = 0
    entry.history = {}
    entry.lastUpdate = os.time()
    saveSuspicion()

    print(('[RESET SUSPECT] Staff=%s | Target=%s(%d) | %d -> 0'):format(staffName(src), tName, target, oldScore))

    staffLogCheck('🧹 Reset suspicion', {
        { name = 'Staff', value = ('`%s` (`%d`)'):format(staffName(src), src), inline = false },
        { name = 'Cible', value = ('`%s` (`%d`)'):format(tName, target), inline = false },
        { name = 'IDs', value = idsToText(ids, target), inline = false },
        { name = 'Ancien score', value = ('`%d/%d`'):format(oldScore, Suspicion.maxScore), inline = true },
        { name = 'Nouveau score', value = ('`0/%d`'):format(Suspicion.maxScore), inline = true },
    }, { staff = src, target = target, key = key, oldScore = oldScore })

    if src ~= 0 then
        TriggerClientEvent('chat:addMessage', src, { args = { '^2ResetSuspect', ('%s (%d) | %d -> 0'):format(tName, target, oldScore) } })
    end
end, false)

-- /topsuspects
RegisterCommand('topsuspects', function(src)
    if not staffAllowed(src, 'logsgali.topsuspects') and not staffAllowed(src, 'logsgali.suspect') then
        if src ~= 0 then TriggerClientEvent('chat:addMessage', src, { args = { '^1Accès refusé', "Permission requise." } }) end
        return
    end

    local arr = {}
    for k, v in pairs(suspicionData) do
        arr[#arr + 1] = { key = k, score = tonumber(v.score) or 0 }
    end
    table.sort(arr, function(a, b) return a.score > b.score end)

    local top = {}
    for i = 1, math.min(10, #arr) do
        top[#top + 1] = ('%d) `%s` → `%d/%d`'):format(i, arr[i].key, arr[i].score, Suspicion.maxScore)
    end

    local text = (#top > 0) and table.concat(top, '\n') or '`Aucun suspect`'

    print('[TOP SUSPECTS] Requested by ' .. staffName(src))
    print(text)

    staffLogCheck('📈 Top suspects', {
        { name = 'Staff', value = ('`%s` (`%d`)'):format(staffName(src), src), inline = false },
        { name = 'Top 10', value = text, inline = false },
    }, { staff = src, top = arr })

    if src ~= 0 then
        TriggerClientEvent('chat:addMessage', src, { args = { '^3TopSuspects', text } })
    end
end, false)

-- /suspecthistory <id>
RegisterCommand('suspecthistory', function(src, args)
    if not staffAllowed(src, 'logsgali.suspecthistory') and not staffAllowed(src, 'logsgali.suspect') then
        if src ~= 0 then TriggerClientEvent('chat:addMessage', src, { args = { '^1Accès refusé', "Permission requise." } }) end
        return
    end

    local target = tonumber(args[1] or '')
    if not target then
        local msg = 'Usage: suspecthistory <serverId>'
        print(msg)
        if src ~= 0 then TriggerClientEvent('chat:addMessage', src, { args = { '^1Usage', '/suspecthistory <serverId>' } }) end
        return
    end

    if GetPlayerName(target) == nil then
        local msg = ('Joueur introuvable: %s'):format(target)
        print(msg)
        if src ~= 0 then TriggerClientEvent('chat:addMessage', src, { args = { '^1Erreur', msg } }) end
        return
    end

    local key = getPlayerKey(target)
    local entry = suspicionData[key]
    local ids = getPlayerIds(target)
    local tName = GetPlayerName(target) or ('ID %d'):format(target)

    if not entry then
        local msg = ('Aucun historique pour %s (%d)'):format(tName, target)
        print(msg)
        if src ~= 0 then TriggerClientEvent('chat:addMessage', src, { args = { '^3History', msg } }) end
        return
    end

    local histFull = formatHistory(entry, 40)
    local summary = formatHistory(entry, 10)

    print(('[SUSPECT HISTORY] Staff=%s | Target=%s(%d) | Score=%d/%d'):format(staffName(src), tName, target, entry.score or 0, Suspicion.maxScore))
    print(idsToText(ids, target))
    print(histFull)

    staffLogCheck('📜 Historique suspicion', {
        { name = 'Staff', value = ('`%s` (`%d`)'):format(staffName(src), src), inline = false },
        { name = 'Cible', value = ('`%s` (`%d`)'):format(tName, target), inline = false },
        { name = 'Score', value = ('`%d/%d`'):format(entry.score or 0, Suspicion.maxScore), inline = true },
        { name = 'IDs', value = idsToText(ids, target), inline = false },
        { name = 'Historique (max 40)', value = histFull, inline = false },
    }, { staff = src, target = target, key = key, score = entry.score, history = entry.history })

    if src ~= 0 then
        TriggerClientEvent('chat:addMessage', src, { args = { '^3History', ('%s (%d)\n%s'):format(tName, target, summary) } })
    end
end, false)

--=====================================================
-- PANEL SUSPECT (ox_lib callbacks) + Actions staff
--=====================================================
local function aceAllowed(src, ace)
    if src == 0 then return true end
    return IsPlayerAceAllowed(src, ace)
end

local function keyToOnlinePlayer(key)
    for _, s in pairs(GetPlayers()) do
        local src = tonumber(s)
        if src and GetPlayerName(src) then
            if getPlayerKey(src) == key then
                return src
            end
        end
    end
    return nil
end

local function topSuspects(limit)
    limit = tonumber(limit) or 10
    local arr = {}
    for k, v in pairs(suspicionData) do
        arr[#arr + 1] = { key = k, score = tonumber(v.score) or 0, lastUpdate = v.lastUpdate or 0 }
    end
    table.sort(arr, function(a,b) return a.score > b.score end)

    local out = {}
    for i = 1, math.min(limit, #arr) do
        local k = arr[i].key
        local online = keyToOnlinePlayer(k)
        out[#out + 1] = {
            key = k,
            score = arr[i].score,
            online = online and true or false,
            serverId = online,
            name = online and (GetPlayerName(online) or 'N/A') or nil
        }
    end
    return out
end

local function onlineSuspects(minScore)
    minScore = tonumber(minScore) or Suspicion.threshold
    local out = {}
    for _, s in pairs(GetPlayers()) do
        local src = tonumber(s)
        if src and GetPlayerName(src) then
            local key = getPlayerKey(src)
            local entry = suspicionData[key]
            local score = entry and (tonumber(entry.score) or 0) or 0
            if score >= minScore then
                out[#out + 1] = { key = key, score = score, serverId = src, name = GetPlayerName(src) or 'N/A' }
            end
        end
    end
    table.sort(out, function(a,b) return a.score > b.score end)
    return out
end

-- callbacks panel
lib.callback.register('logsgali:cb_getTopSuspects', function(src, limit)
    if not aceAllowed(src, 'logsgali.panelsuspect') then
        return { ok = false, error = 'no_permission' }
    end
    return { ok = true, data = topSuspects(limit or 10) }
end)

lib.callback.register('logsgali:cb_getOnlineSuspects', function(src, minScore)
    if not aceAllowed(src, 'logsgali.panelsuspect') then
        return { ok = false, error = 'no_permission' }
    end
    return { ok = true, data = onlineSuspects(minScore or Suspicion.threshold) }
end)

lib.callback.register('logsgali:cb_getSuspectDetails', function(src, key)
    if not aceAllowed(src, 'logsgali.panelsuspect') then
        return { ok = false, error = 'no_permission' }
    end
    if not key or key == '' then
        return { ok = false, error = 'missing_key' }
    end

    local entry = suspicionData[key]
    local serverId = keyToOnlinePlayer(key)

    if not entry then
        return { ok = true, data = { key = key, score = 0, history = {}, serverId = serverId } }
    end

    local history = entry.history or {}
    local sliced = {}
    local start = math.max(1, #history - 19)
    for i = start, #history do
        sliced[#sliced + 1] = history[i]
    end

    return {
        ok = true,
        data = {
            key = key,
            score = tonumber(entry.score) or 0,
            lastUpdate = entry.lastUpdate,
            history = sliced,
            serverId = serverId
        }
    }
end)

lib.callback.register('logsgali:cb_resetSuspect', function(src, key)
    if not aceAllowed(src, 'logsgali.resetsuspect') then
        return { ok = false, error = 'no_permission' }
    end
    if not key or key == '' then
        return { ok = false, error = 'missing_key' }
    end

    local entry = suspicionData[key]
    if not entry then
        return { ok = false, error = 'not_found' }
    end

    local old = tonumber(entry.score) or 0
    entry.score = 0
    entry.history = {}
    entry.lastUpdate = os.time()
    saveSuspicion()

    staffLogCheck('🧹 Reset suspicion (panel)', {
        { name = 'Staff', value = ('`%s` (`%d`)'):format(staffName(src), src), inline = false },
        { name = 'Key', value = ('`%s`'):format(key), inline = false },
        { name = 'Ancien score', value = ('`%d/%d`'):format(old, Suspicion.maxScore), inline = true },
        { name = 'Nouveau score', value = ('`0/%d`'):format(Suspicion.maxScore), inline = true },
    }, { staff = src, key = key, oldScore = old })

    return { ok = true, oldScore = old, newScore = 0 }
end)

--========================
-- ACTIONS STAFF (TP/BRING/FREEZE/SPECTATE) via panel
--========================
local frozenPlayers = {}

local function logStaffAction(src, target, action)
    staffLogCheck('🛡️ Action staff (panel)', {
        { name = 'Staff', value = ('`%s` (`%d`)'):format(staffName(src), src), inline = false },
        { name = 'Cible', value = ('`%s` (`%d`)'):format(GetPlayerName(target) or 'N/A', target), inline = false },
        { name = 'Action', value = ('`%s`'):format(action), inline = false },
    }, { staff = src, target = target, action = action })
end

lib.callback.register('logsgali:tpToPlayer', function(src, target)
    if not aceAllowed(src, 'logsgali.tp') then return { ok = false, error = 'no_permission' } end
    target = tonumber(target)
    if not target or GetPlayerName(target) == nil then return { ok = false, error = 'target_offline' } end

    TriggerClientEvent('logsgali:tp', src, target)
    logStaffAction(src, target, 'TP sur joueur')
    return { ok = true }
end)

lib.callback.register('logsgali:bringPlayer', function(src, target)
    if not aceAllowed(src, 'logsgali.bring') then return { ok = false, error = 'no_permission' } end
    target = tonumber(target)
    if not target or GetPlayerName(target) == nil then return { ok = false, error = 'target_offline' } end

    TriggerClientEvent('logsgali:bring', target, src)
    logStaffAction(src, target, 'Bring joueur')
    return { ok = true }
end)

lib.callback.register('logsgali:toggleFreeze', function(src, target)
    if not aceAllowed(src, 'logsgali.freeze') then return { ok = false, error = 'no_permission' } end
    target = tonumber(target)
    if not target or GetPlayerName(target) == nil then return { ok = false, error = 'target_offline' } end

    frozenPlayers[target] = not frozenPlayers[target]
    TriggerClientEvent('logsgali:freeze', target, frozenPlayers[target])
    logStaffAction(src, target, frozenPlayers[target] and 'Freeze joueur' or 'Unfreeze joueur')
    return { ok = true, frozen = frozenPlayers[target] }
end)

lib.callback.register('logsgali:spectate', function(src, target)
    if not aceAllowed(src, 'logsgali.spectate') then return { ok = false, error = 'no_permission' } end
    target = tonumber(target)
    if not target or GetPlayerName(target) == nil then return { ok = false, error = 'target_offline' } end

    TriggerClientEvent('logsgali:spectate', src, target)
    logStaffAction(src, target, 'Spectate joueur (toggle)')
    return { ok = true }
end)

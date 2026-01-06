--========================================
-- logsgali - client.lua (COMPLET)
-- - Shot logs
-- - Death logs
-- - /panelsuspect (ox_lib) + actions staff:
--   TP / Bring / Freeze / Spectate
-- - Barème visible dans le panel
--========================================

local lastShot = 0
local wasDead = false

-- arme actuelle en item ox_inventory (ex: WEAPON_APPISTOL)
local currentWeaponItem = nil

-- ox_inventory:currentWeapon donne l'item équipé
AddEventHandler('ox_inventory:currentWeapon', function(weapon)
    if weapon and weapon.name then
        currentWeaponItem = weapon.name
    else
        currentWeaponItem = nil
    end
end)

--=====================================================
-- Helpers Death/Shot
--=====================================================
local function getKillerServerId(ped)
    local killer = GetPedSourceOfDeath(ped)
    if killer == 0 then return nil end

    if IsEntityAPed(killer) then
        local playerIndex = NetworkGetPlayerIndexFromPed(killer)
        if playerIndex and playerIndex ~= -1 then
            return GetPlayerServerId(playerIndex)
        end
    end

    return nil
end

local function damageTypeLabel(dmgType)
    local map = {
        [0] = 'Unknown',
        [1] = 'Melee',
        [2] = 'Bullet',
        [3] = 'Explosive',
        [4] = 'Fire',
        [5] = 'Fall/Impact',
        [6] = 'Gas',
        [7] = 'Drown',
    }
    return map[dmgType] or ('Type ' .. tostring(dmgType))
end

--=====================================================
-- PANEL SUSPECT (ox_lib)
--=====================================================
local function fmtHistory(history)
    if type(history) ~= 'table' or #history == 0 then
        return 'Aucun trigger.'
    end

    local lines = {}
    for i = 1, #history do
        local h = history[i]
        lines[#lines + 1] = string.format("• [%s] +%s — %s",
            h.t or '?',
            tostring(h.points or 0),
            tostring(h.reason or 'N/A')
        )
    end

    local txt = table.concat(lines, '\n')
    if #txt > 950 then
        txt = txt:sub(1, 950) .. "\n…"
    end
    return txt
end

--=====================================================
-- BAREME (global) ✅
--=====================================================
local function openBareme()
    lib.registerContext({
        id = 'logsgali_panel_bareme',
        title = 'Barème Suspicion',
        options = {
            { title = '💰 Grosse somme', description = 'Réception >= 500.000$  ➜  +35 points', icon = 'money-bill-wave', disabled = true },
            { title = '🔫 Arme spéciale', description = 'Réception MK2 ou Heavy Weapon  ➜  +30 points', icon = 'gun', disabled = true },
            { title = '💥 Kill spam', description = '> 5 kills en moins de 5 minutes  ➜  +25 points', icon = 'skull', disabled = true },
            { title = '📈 Kill total élevé', description = 'Streak total (ex: 50, puis +10)  ➜  +15 points', icon = 'chart-line', disabled = true },
            { title = '📦 Duplication suspecte', description = 'Spam ajout item identique très rapide  ➜  +40 points', icon = 'clone', disabled = true },
            { title = '💥 Crash après transfert suspect', description = 'Crash < 10s après transfert suspect  ➜  +35 points', icon = 'triangle-exclamation', disabled = true },
            { title = '🧊 Decay', description = 'Le score baisse automatiquement: -1 point / minute (si inactif)', icon = 'clock', disabled = true },
            { title = '🚨 Seuil alerte', description = 'Alerte staff à partir de 70/100 (cooldown alert 5 min)', icon = 'bell', disabled = true },
            {
                title = 'Retour',
                icon = 'arrow-left',
                onSelect = function()
                    lib.showContext('logsgali_panel_main')
                end
            }
        }
    })

    lib.showContext('logsgali_panel_bareme')
end

local function openSuspectDetails(data, labelTitle)
    data = data or {}
    local key = data.key
    if not key or key == '' then
        return lib.notify({ type = 'error', description = 'Clé suspect invalide.' })
    end

    local score = tonumber(data.score) or 0
    local serverId = tonumber(data.serverId)
    local online = serverId and serverId > 0

    local historyTxt = fmtHistory(data.history or {})

    local opts = {}

    opts[#opts + 1] = {
        title = ('Score: %d/100'):format(score),
        description = 'Derniers triggers (max 20)',
        icon = 'triangle-exclamation',
        disabled = true
    }

    opts[#opts + 1] = {
        title = 'Historique',
        description = historyTxt,
        icon = 'list',
        disabled = true
    }

    -- Actions staff seulement si online
    if online then
        opts[#opts + 1] = {
            title = 'TP sur lui',
            icon = 'location-arrow',
            description = 'Téléportation sur le joueur',
            onSelect = function()
                local r = lib.callback.await('logsgali:tpToPlayer', false, serverId)
                if not r or not r.ok then
                    lib.notify({ type = 'error', description = 'TP refusé: ' .. tostring(r and r.error or 'unknown') })
                else
                    lib.notify({ type = 'success', description = 'TP effectué.' })
                end
            end
        }

        opts[#opts + 1] = {
            title = 'Bring',
            icon = 'hand',
            description = 'Ramener le joueur sur toi',
            onSelect = function()
                local r = lib.callback.await('logsgali:bringPlayer', false, serverId)
                if not r or not r.ok then
                    lib.notify({ type = 'error', description = 'Bring refusé: ' .. tostring(r and r.error or 'unknown') })
                else
                    lib.notify({ type = 'success', description = 'Bring effectué.' })
                end
            end
        }

        opts[#opts + 1] = {
            title = 'Freeze / Unfreeze',
            icon = 'snowflake',
            description = 'Bloquer/débloquer le joueur',
            onSelect = function()
                local r = lib.callback.await('logsgali:toggleFreeze', false, serverId)
                if not r or not r.ok then
                    lib.notify({ type = 'error', description = 'Freeze refusé: ' .. tostring(r and r.error or 'unknown') })
                else
                    lib.notify({ type = 'success', description = r.frozen and 'Joueur freeze.' or 'Joueur unfreeze.' })
                end
            end
        }

        opts[#opts + 1] = {
            title = 'Spectate (toggle)',
            icon = 'eye',
            description = 'Activer/Désactiver le mode spectate',
            onSelect = function()
                local r = lib.callback.await('logsgali:spectate', false, serverId)
                if not r or not r.ok then
                    lib.notify({ type = 'error', description = 'Spectate refusé: ' .. tostring(r and r.error or 'unknown') })
                end
            end
        }
    end

    -- Reset
    opts[#opts + 1] = {
        title = 'Reset / Clear (remet à 0)',
        description = 'Nécessite permission logsgali.resetsuspect',
        icon = 'trash',
        onSelect = function()
            local confirm = lib.alertDialog({
                header = 'Confirmation',
                content = ('Reset suspicion pour:\n%s\n\nScore actuel: %d/100'):format(key, score),
                centered = true,
                cancel = true
            })
            if confirm ~= 'confirm' then return end

            local r = lib.callback.await('logsgali:cb_resetSuspect', false, key)
            if r and r.ok then
                lib.notify({ type = 'success', description = ('Reset OK: %d -> 0'):format(r.oldScore or score) })
                local res = lib.callback.await('logsgali:cb_getSuspectDetails', false, key)
                if res and res.ok then
                    openSuspectDetails(res.data, labelTitle)
                end
            else
                lib.notify({ type = 'error', description = 'Reset refusé: ' .. tostring(r and r.error or 'unknown') })
            end
        end
    }

    opts[#opts + 1] = {
        title = 'Retour',
        icon = 'arrow-left',
        onSelect = function()
            lib.showContext('logsgali_panel_main')
        end
    }

    lib.registerContext({
        id = 'logsgali_panel_suspect_details',
        title = labelTitle or ('Suspect: ' .. key),
        options = opts
    })

    lib.showContext('logsgali_panel_suspect_details')
end

local function openTopSuspects()
    local res = lib.callback.await('logsgali:cb_getTopSuspects', false, 10)
    if not res or not res.ok then
        return lib.notify({ type = 'error', description = 'Impossible de charger Top Suspects.' })
    end

    local opts = {
        {
            title = '↻ Refresh',
            icon = 'rotate',
            onSelect = function()
                openTopSuspects()
            end
        }
    }

    for _, s in ipairs(res.data or {}) do
        local score = tonumber(s.score) or 0
        local title = s.online and ("🟢 " .. (s.name or 'Online')) or "⚪ Offline"
        local desc = s.serverId and ("ServerID: " .. s.serverId .. "\nKey: " .. s.key) or ("Key: " .. s.key)

        opts[#opts + 1] = {
            title = string.format("%s — %d/100", title, score),
            description = desc,
            icon = 'user-secret',
            onSelect = function()
                local d = lib.callback.await('logsgali:cb_getSuspectDetails', false, s.key)
                if d and d.ok then
                    local label = s.serverId and (('Suspect: %s (%d)'):format(s.name or 'N/A', s.serverId)) or ('Suspect: ' .. s.key)
                    openSuspectDetails(d.data, label)
                else
                    lib.notify({ type = 'error', description = 'Erreur details suspect.' })
                end
            end
        }
    end

    opts[#opts + 1] = {
        title = 'Retour',
        icon = 'arrow-left',
        onSelect = function()
            lib.showContext('logsgali_panel_main')
        end
    }

    lib.registerContext({
        id = 'logsgali_panel_top',
        title = 'Top Suspects',
        options = opts
    })

    lib.showContext('logsgali_panel_top')
end

local function openOnlineSuspects()
    local res = lib.callback.await('logsgali:cb_getOnlineSuspects', false, 70)
    if not res or not res.ok then
        return lib.notify({ type = 'error', description = 'Impossible de charger suspects online.' })
    end

    local opts = {
        {
            title = '↻ Refresh',
            icon = 'rotate',
            onSelect = function()
                openOnlineSuspects()
            end
        }
    }

    local list = res.data or {}
    if #list == 0 then
        opts[#opts + 1] = {
            title = 'Aucun suspect online (>=70)',
            icon = 'circle-check',
            disabled = true
        }
    else
        for _, s in ipairs(list) do
            local score = tonumber(s.score) or 0
            opts[#opts + 1] = {
                title = string.format("🟢 %s (%d) — %d/100", s.name or 'N/A', s.serverId or -1, score),
                description = "Key: " .. (s.key or 'N/A'),
                icon = 'user',
                onSelect = function()
                    local d = lib.callback.await('logsgali:cb_getSuspectDetails', false, s.key)
                    if d and d.ok then
                        openSuspectDetails(d.data, ('Suspect: %s (%d)'):format(s.name or 'N/A', s.serverId or -1))
                    else
                        lib.notify({ type = 'error', description = 'Erreur details suspect.' })
                    end
                end
            }
        end
    end

    opts[#opts + 1] = {
        title = 'Retour',
        icon = 'arrow-left',
        onSelect = function()
            lib.showContext('logsgali_panel_main')
        end
    }

    lib.registerContext({
        id = 'logsgali_panel_online',
        title = 'Suspects détectés (online)',
        options = opts
    })

    lib.showContext('logsgali_panel_online')
end

local function openMainPanel()
    lib.registerContext({
        id = 'logsgali_panel_main',
        title = 'Panel Suspect',
        options = {
            {
                title = 'Top Suspects',
                description = 'Top 10 des scores (online/offline)',
                icon = 'trophy',
                onSelect = openTopSuspects
            },
            {
                title = 'Suspects détectés (online)',
                description = 'Joueurs online score >= 70',
                icon = 'radar',
                onSelect = openOnlineSuspects
            },
            {
                title = 'Barème Suspicion',
                description = 'Voir les règles et points (+35, +30, etc.)',
                icon = 'scale-balanced',
                onSelect = openBareme
            },
            {
                title = 'Fermer',
                icon = 'xmark',
                onSelect = function() end
            }
        }
    })

    lib.showContext('logsgali_panel_main')
end

RegisterCommand('panelsuspect', function()
    openMainPanel()
end, false)

-- Suggestion chat (si chat resource)
CreateThread(function()
    Wait(1000)
    TriggerEvent('chat:addSuggestion', '/panelsuspect', 'Ouvre le panel suspect (staff)')
end)

--=====================================================
-- EVENTS STAFF ACTIONS (reçus du serveur)
--=====================================================
RegisterNetEvent('logsgali:tp', function(target)
    local ped = PlayerPedId()
    local tPed = GetPlayerPed(GetPlayerFromServerId(target))
    if not DoesEntityExist(tPed) then
        return lib.notify({ type = 'error', description = 'Cible introuvable.' })
    end
    local coords = GetEntityCoords(tPed)
    SetEntityCoords(ped, coords.x, coords.y, coords.z + 1.0, false, false, false, false)
end)

RegisterNetEvent('logsgali:bring', function(staff)
    local ped = PlayerPedId()
    local sPed = GetPlayerPed(GetPlayerFromServerId(staff))
    if not DoesEntityExist(sPed) then
        return lib.notify({ type = 'error', description = 'Staff introuvable.' })
    end
    local coords = GetEntityCoords(sPed)
    SetEntityCoords(ped, coords.x, coords.y, coords.z + 1.0, false, false, false, false)
end)

RegisterNetEvent('logsgali:freeze', function(state)
    local ped = PlayerPedId()
    FreezeEntityPosition(ped, state == true)
end)

local spectating = false
local lastCoords = nil

RegisterNetEvent('logsgali:spectate', function(target)
    local ped = PlayerPedId()

    if not spectating then
        local tPed = GetPlayerPed(GetPlayerFromServerId(target))
        if not DoesEntityExist(tPed) then
            return lib.notify({ type = 'error', description = 'Cible introuvable.' })
        end

        lastCoords = GetEntityCoords(ped)
        spectating = true
        NetworkSetInSpectatorMode(true, tPed)
        lib.notify({ type = 'inform', description = 'Mode spectate activé (retape Spectate pour quitter).' })
    else
        spectating = false
        NetworkSetInSpectatorMode(false, ped)
        if lastCoords then
            SetEntityCoords(ped, lastCoords.x, lastCoords.y, lastCoords.z, false, false, false, false)
        end
        lib.notify({ type = 'inform', description = 'Mode spectate désactivé.' })
    end
end)

--=====================================================
-- LOOP: Death + Shot
--=====================================================
CreateThread(function()
    while true do
        Wait(100)

        local ped = PlayerPedId()
        if not DoesEntityExist(ped) then goto continue end

        -- Mort : vivant -> mort (une seule fois)
        local dead = IsEntityDead(ped)
        if dead and not wasDead then
            wasDead = true

            local weaponHash = GetPedCauseOfDeath(ped)
            local killerServerId = getKillerServerId(ped)
            local dmgType = GetWeaponDamageType(weaponHash)

            TriggerServerEvent('ox_logs:died', {
                killerServerId = killerServerId,
                weaponHash = weaponHash,
                damageType = dmgType,
                damageTypeLabel = damageTypeLabel(dmgType),
            })
        elseif not dead and wasDead then
            wasDead = false
        end

        -- Tir (anti-spam)
        if IsPedShooting(ped) then
            local nowMs = GetGameTimer()
            local cd = (Config and Config.ShootCooldown) or 1200
            if (nowMs - lastShot) >= cd then
                lastShot = nowMs

                local hash = GetSelectedPedWeapon(ped)

                TriggerServerEvent('ox_logs:shot', {
                    weaponHash = hash,
                    weaponItem = currentWeaponItem,
                })
            end
        end

        ::continue::
    end
end)

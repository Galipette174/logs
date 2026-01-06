fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'Galipette'
description 'Logs + Suspicion System + Staff Panel'
version '1.0.0'

shared_scripts {
    '@ox_lib/init.lua',
    'shared.lua'
}

server_scripts {
    'server.lua'
}

client_scripts {
    'client.lua'
}

dependencies {
    'ox_lib',
    'ox_inventory'
}

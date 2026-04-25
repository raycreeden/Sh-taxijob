fx_version 'cerulean'
autor 'SherlockCo'
game 'gta5'
lua54 'yes'

name 'sh-taxijob'
description 'Taxi Job - Compatible QBCore & QBX'
version '1.0.0'

shared_scripts {
    'config/config.lua',
}

client_scripts {
    'client/client.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server/server.lua',
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/style.css',
    'html/script.js',
}

-- La carpeta data/ se crea automaticamente por el server con SaveResourceFile.
-- panel_perms.json se genera en: resources/sh-taxijob/data/panel_perms.json

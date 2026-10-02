// Выполняется один раз, при первом запуске на пустом каталоге данных: образ mongo
// запускает скрипты из /docker-entrypoint-initdb.d от имени root (его создают
// MONGO_INITDB_ROOT_*). Заводит пользователя приложения, который видит только свою
// базу: backend и socket ходят под ним, а не под root.
//
// Пользователь лежит в базе admin, поэтому в строке подключения нужен
// ?authSource=admin. Если каталог данных уже инициализирован, скрипт не
// запускается: пользователя в этом случае меняют руками через mongosh.
const user = process.env.MONGO_APP_USER;
const password = process.env.MONGO_APP_PASSWORD;
const name = process.env.MONGO_APP_DB;

if (!user || !password || !name) {
    throw new Error(
        'Set MONGO_APP_USER, MONGO_APP_PASSWORD and MONGO_APP_DB in env/mongo.env',
    );
}

db.getSiblingDB('admin').createUser({
    user,
    pwd: password,
    roles: [{ role: 'readWrite', db: name }],
});
print(`created user "${user}" with readWrite on "${name}"`);

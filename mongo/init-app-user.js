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

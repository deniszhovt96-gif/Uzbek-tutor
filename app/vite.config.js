// base './' — приложение работает по любому адресу GitHub Pages
// (https://<логин>.github.io/<репозиторий>/) без привязки к имени репозитория.
export default {
  base: './',
  define: {
    __BUILD_TIME__: JSON.stringify(new Date().toISOString()),
  },
};

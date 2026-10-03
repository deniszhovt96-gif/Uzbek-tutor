// Настройки подключения. Публичный ключ подставляется при сборке (GitHub Variables).
export const SUPABASE_URL = 'https://jjvtkvritnmwqfpvlxrs.supabase.co';
export const SUPABASE_KEY = import.meta.env.VITE_SUPABASE_KEY || '';
// Аудио: word_{id}.mp3 и word_{id}_ex{n}.mp3. При переезде хранилища меняется только эта строка.
export const AUDIO_BASE = 'https://deniszhovt96-gif.github.io/uzbek-audio/audio/';

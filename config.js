// Site configuration — the ONLY file to edit when connecting the client's database.
//
// 1. In the client's Supabase project: Project Settings → API.
// 2. Copy "Project URL" into supabaseUrl and the "anon public" key into supabaseKey.
//    (The anon key is designed to be public; the database's row-level security is what protects data.)
// 3. Push. Every browser now shares one live database.
//
// Leave both empty and the site runs in demo mode: everything stays in each visitor's own browser.
window.ALEM_CONFIG = {
  supabaseUrl: 'https://wwyrkqhcllokkozabmnh.supabase.co',
  supabaseKey: 'sb_publishable_txaqbo3BQNLygbOe_aiemA_KDbODAFk'
};

// تضمین تراز — نسخهٔ ویندوز: پنجرهٔ برنامه که نسخهٔ وب سرور را باز می‌کند
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
fn main() {
    tauri::Builder::default()
        .run(tauri::generate_context!())
        .expect("error while running Tazmin Taraz");
}

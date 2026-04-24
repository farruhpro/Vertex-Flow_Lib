bl_info = {
    "name": "Vertex Flow Integration",
    "author": "Farrukh Gulamjanov",
    "version": (1, 1),
    "blender": (3, 0, 0),
    "location": "View3D > Sidebar > Vertex Flow",
    "description": "Интеграция с Vertex Flow: Авто-импорт и лог событий",
    "category": "Import-Export",
}

import bpy
import os
import json
import tempfile

# Хранилище для последних логов (чтобы видеть их в интерфейсе)
class VF_Logs:
    messages = []

    @classmethod
    def add(cls, msg):
        cls.messages.append(msg)
        if len(cls.messages) > 10: # Храним только последние 10 записей
            cls.messages.pop(0)

# --- ПАНЕЛЬ В ИНТЕРФЕЙСЕ (N-Panel) ---
class VIEW3D_PT_vertex_flow(bpy.types.Panel):
    bl_space_type = 'VIEW_3D'
    bl_region_type = 'UI'
    bl_category = 'Vertex Flow'
    bl_label = 'Vertex Flow Status'

    def draw(self, context):
        layout = self.layout
        
        # Статус слушателя
        row = layout.row()
        row.label(text="Слушатель: Работает", icon='RADIOBUT_ON')
        
        layout.separator()
        layout.label(text="Лог последних событий:")
        
        # Вывод сообщений лога
        box = layout.box()
        if not VF_Logs.messages:
            box.label(text="Ожидание задач...", icon='INFO')
        else:
            for msg in reversed(VF_Logs.messages):
                box.label(text=msg)
        
        layout.operator("vf.clear_logs", text="Очистить лог", icon='TRASH')

# Оператор очистки лога
class VF_OT_clear_logs(bpy.types.Operator):
    bl_idname = "vf.clear_logs"
    bl_label = "Clear Vertex Flow Logs"
    
    def execute(self, context):
        VF_Logs.messages.clear()
        return {'FINISHED'}

# --- ЛОГИКА ИМПОРТА ---
def relink_textures(textures_dir):
    if not textures_dir or not os.path.exists(textures_dir):
        return
    norm_dir = os.path.normpath(textures_dir)
    count = 0
    for img in bpy.data.images:
        if img.filepath:
            filename = bpy.path.basename(img.filepath)
            new_path = os.path.join(norm_dir, filename)
            if os.path.exists(new_path):
                img.filepath = new_path
                count += 1
    if count > 0:
        VF_Logs.add(f"Перелинковано текстур: {count}")

def vertex_flow_listener():
    temp_dir = tempfile.gettempdir()
    task_file = os.path.join(temp_dir, "vertex_flow_task.json")

    if not os.path.exists(task_file):
        return 1.0 

    try:
        with open(task_file, 'r', encoding='utf-8') as f:
            data = json.load(f)

        model_path = data.get("model_path", "")
        project_path = data.get("project_path", "")
        textures_path = data.get("textures_path", "")

        if not model_path or not project_path:
            os.remove(task_file)
            return 1.0

        current_path = bpy.data.filepath
        if not current_path:
            VF_Logs.add("ОШИБКА: Сцена не сохранена!")
            os.remove(task_file)
            return 1.0

        if os.path.normpath(current_path).lower() == os.path.normpath(project_path).lower():
            os.remove(task_file)
            
            if os.path.exists(model_path):
                ext = os.path.splitext(model_path)[1].lower()
                VF_Logs.add(f"Импорт: {os.path.basename(model_path)}")
                
                if ext == ".blend":
                    with bpy.data.libraries.load(model_path, link=False) as (data_from, data_to):
                        data_to.objects = data_from.objects
                    for obj in data_to.objects:
                        if obj: bpy.context.collection.objects.link(obj)
                elif ext == ".fbx":
                    bpy.ops.import_scene.fbx(filepath=model_path)
                elif ext == ".obj":
                    if hasattr(bpy.ops.wm, "obj_import"): bpy.ops.wm.obj_import(filepath=model_path)
                    else: bpy.ops.import_scene.obj(filepath=model_path)
                
                if textures_path:
                    relink_textures(textures_path)
                
                VF_Logs.add("✅ Готово")
                
    except Exception as e:
        VF_Logs.add(f"Ошибка: {str(e)[:30]}...")
        if os.path.exists(task_file): os.remove(task_file)

    return 1.0

# --- РЕГИСТРАЦИЯ ---
classes = (VIEW3D_PT_vertex_flow, VF_OT_clear_logs)

# 1. Функция отложенного запуска (ждет полной загрузки Blender)
@bpy.app.handlers.persistent
def vf_start_timer_handler(dummy):
    if not bpy.app.timers.is_registered(vertex_flow_listener):
        bpy.app.timers.register(vertex_flow_listener)

# 2. Основная регистрация
def register():
    for cls in classes:
        # Защита от дублирования интерфейса
        if not hasattr(bpy.types, cls.__name__):
            bpy.utils.register_class(cls)
    
    # Пробуем запустить слушатель (сработает при ручной установке)
    if not bpy.app.timers.is_registered(vertex_flow_listener):
        try:
            bpy.app.timers.register(vertex_flow_listener)
        except Exception:
            pass # Если загрузка ранняя — игнорируем ошибку
            
    # Вешаем хук, который гарантированно запустит слушатель после старта Blender
    if vf_start_timer_handler not in bpy.app.handlers.load_post:
        bpy.app.handlers.load_post.append(vf_start_timer_handler)

def unregister():
    for cls in reversed(classes):
        if hasattr(bpy.types, cls.__name__):
            bpy.utils.unregister_class(cls)
    if bpy.app.timers.is_registered(vertex_flow_listener):
        bpy.app.timers.unregister(vertex_flow_listener)
    # Убираем хук при удалении скрипта
    if vf_start_timer_handler in bpy.app.handlers.load_post:
        bpy.app.handlers.load_post.remove(vf_start_timer_handler)

# 3. Железобетонный автозапуск для папки startup
# Blender сам не вызывает register() из папки startup, поэтому мы делаем это принудительно
try:
    register()
except Exception:
    pass

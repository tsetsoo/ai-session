use rusqlite::Row;
use todo_shared::{ConversationStatus, Importance, Section, Todo};

pub fn row_to_todo(row: &Row) -> rusqlite::Result<Todo> {
    let id: String = row.get("id")?;
    let section_str: String = row.get("section")?;
    let title: String = row.get("title")?;
    let completed: bool = row.get::<_, i32>("completed")? != 0;
    let importance_str: String = row.get("importance")?;
    let due_date: Option<String> = row.get("due_date")?;
    let daily_date: Option<String> = row.get("daily_date")?;
    let carried_from: Option<String> = row.get("carried_from")?;
    let created_at: String = row.get("created_at")?;
    let updated_at: String = row.get("updated_at")?;
    let completed_at: Option<String> = row.get("completed_at")?;
    let conversation_status: Option<String> = row.get("conversation_status")?;

    let section = Section::parse(&section_str).unwrap_or(Section::P);
    let importance = Importance::parse(&importance_str).unwrap_or_default();
    let conversation_status = conversation_status.as_deref().and_then(ConversationStatus::parse);

    Ok(Todo {
        id,
        section,
        title,
        completed,
        importance,
        due_date,
        daily_date,
        carried_from,
        created_at,
        updated_at,
        completed_at,
        conversation_status,
    })
}

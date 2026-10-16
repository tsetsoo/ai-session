use leptos::*;
use todo_shared::{CreateTodoRequest, Importance, Section};
use wasm_bindgen::JsCast;
use wasm_bindgen_futures::spawn_local;

use crate::api;
use crate::speech;
use super::todo_item::TodoItem;

fn today() -> String {
    let date = js_sys::Date::new_0();
    let y = date.get_full_year();
    let m = date.get_month() + 1;
    let d = date.get_date();
    format!("{y:04}-{m:02}-{d:02}")
}

#[component]
#[allow(clippy::too_many_lines, clippy::needless_pass_by_value)]
pub fn Quadrant(
    section: Section,
    refresh: ReadSignal<usize>,
    set_refresh: WriteSignal<usize>,
    on_open: Callback<Section>,
) -> impl IntoView {
    let (title, set_title) = create_signal(String::new());
    let (importance, set_importance) = create_signal(Importance::Medium);
    let (due_date, set_due_date) = create_signal(String::new());
    let (submitting, set_submitting) = create_signal(false);
    let (listening, set_listening) = create_signal(false);

    let has_speech = speech::is_supported();

    let todos_resource = create_resource(
        move || refresh.get(),
        move |_| async move {
            api::fetch_todos(Some(section.as_str()), Some("importance_date"), None).await.unwrap_or_default()
        },
    );

    let todos = Signal::derive(move || todos_resource.get().unwrap_or_default());
    let count = Signal::derive(move || todos.get().len());

    let do_submit = move || {
        let t = title.get_untracked().trim().to_string();
        if t.is_empty() || submitting.get_untracked() {
            return;
        }
        set_submitting.set(true);
        let imp = importance.get_untracked();
        let dd = due_date.get_untracked();
        let dd_opt = if dd.is_empty() { Some(today()) } else { Some(dd) };
        spawn_local(async move {
            let req = CreateTodoRequest {
                section,
                title: t,
                importance: Some(imp),
                due_date: dd_opt,
                project_id: None,
            };
            let _ = api::create_todo(&req).await;
            set_title.set(String::new());
            set_due_date.set(String::new());
            set_submitting.set(false);
            set_refresh.set(refresh.get_untracked() + 1);
        });
    };

    let submit_click = move |_| do_submit();
    let submit_key = move |ev: web_sys::KeyboardEvent| {
        if ev.key() == "Enter" {
            do_submit();
        }
    };

    let on_mic = move |_| {
        if listening.get_untracked() {
            return;
        }
        set_listening.set(true);
        speech::start_recognition(move |transcript| {
            set_listening.set(false);
            if !transcript.is_empty() {
                let current = title.get_untracked();
                if current.is_empty() {
                    set_title.set(transcript);
                } else {
                    set_title.set(format!("{current} {transcript}"));
                }
            }
        });
    };

    let label = section.as_str();

    view! {
        <div class="quadrant">
            <div class="quadrant-header" style="cursor:pointer" on:click=move |_| on_open.call(section)>
                <h2>{label}</h2>
                <span class="quadrant-count">{count}</span>
                <span class="open-arrow">"\u{2192}"</span>
            </div>
            <div class="quadrant-add">
                <input
                    type="text"
                    placeholder=format!("Add to {label}...")
                    prop:value=title
                    on:input=move |ev| set_title.set(event_target_value(&ev))
                    on:keydown=submit_key
                    prop:disabled=submitting
                />
                {if has_speech {
                    Some(view! {
                        <button
                            class="mic-btn"
                            class:listening=listening
                            on:click=on_mic
                            prop:disabled=listening
                            title="Voice input"
                        >
                            {move || if listening.get() { "\u{25CF}" } else { "\u{1F3A4}" }}
                        </button>
                    })
                } else {
                    None
                }}
                <button
                    class="add-btn"
                    on:click=submit_click
                    prop:disabled=move || submitting.get() || title.get().trim().is_empty()
                >
                    "+"
                </button>
            </div>
            <div class="quadrant-options">
                <select on:change=move |ev| {
                    let val = event_target_value(&ev);
                    if let Some(imp) = Importance::parse(&val) {
                        set_importance.set(imp);
                    }
                }>
                    {Importance::all().iter().map(|imp| {
                        let val = imp.as_str();
                        let lbl = imp.label();
                        let selected = *imp == Importance::Medium;
                        view! { <option value=val selected=selected>{lbl}</option> }
                    }).collect_view()}
                </select>
                <input
                    type="date"
                    prop:value=due_date
                    on:input=move |ev| {
                        let el: web_sys::HtmlInputElement = ev.target().unwrap().unchecked_into();
                        set_due_date.set(el.value());
                    }
                    title="Due date (optional)"
                />
            </div>
            <ul class="todo-list">
                {move || {
                    let items = todos.get();
                    if items.is_empty() {
                        view! { <p class="empty-state">"No todos"</p> }.into_view()
                    } else {
                        items.into_iter().map(|todo| {
                            view! {
                                <TodoItem
                                    todo=todo
                                    on_changed=set_refresh
                                    refresh=refresh
                                />
                            }
                        }).collect_view()
                    }
                }}
            </ul>
        </div>
    }
}

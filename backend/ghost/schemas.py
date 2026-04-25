from typing import Literal, Optional

from pydantic import BaseModel, Field


class ChatMessage(BaseModel):
    role: str
    content: str


class GhostChatRequest(BaseModel):
    code: str
    question: str
    conversation_history: list[ChatMessage] = Field(default_factory=list)
    voice_enabled: bool = False
    filename: Optional[str] = None


class GhostChatResponse(BaseModel):
    detected_language: str
    reply: str
    summary: str
    suggested_actions: list[str]
    tts_enabled: bool
    audio_path: Optional[str]
    tts_error: Optional[str]


class TtsTestRequest(BaseModel):
    text: str


class TtsResponse(BaseModel):
    tts_enabled: bool
    audio_path: Optional[str]
    tts_error: Optional[str]


class ConversationTurn(BaseModel):
    role: Literal["user", "assistant"]
    content: str


class GhostConversationResponse(BaseModel):
    transcript: str
    detected_language: str
    change_summary: str
    diff_preview: str
    reply: str
    suggested_actions: list[str]
    audio_path: Optional[str]
    tts_enabled: bool
    tts_error: Optional[str]

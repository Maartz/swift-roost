-- migrate:up
CREATE TABLE "user_tokens" (
    "id" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    "user_id" UUID NOT NULL REFERENCES "users"("id") ON DELETE CASCADE,
    "token" TEXT NOT NULL,
    "context" TEXT NOT NULL,
    "sent_to" TEXT,
    "created_at" TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX "user_tokens_user_id_index" ON "user_tokens" ("user_id");
CREATE UNIQUE INDEX "user_tokens_token_context_index" ON "user_tokens" ("token", "context");

-- migrate:down
DROP TABLE "user_tokens";
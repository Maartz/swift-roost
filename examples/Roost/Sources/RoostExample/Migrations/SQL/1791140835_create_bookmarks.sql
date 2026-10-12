-- migrate:up
CREATE TABLE "bookmarks" (
    "id" UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    "user_id" UUID NOT NULL REFERENCES "users"("id"),
    "title" TEXT NOT NULL,
    "url" TEXT NOT NULL,
    "note" TEXT NOT NULL,
    "read" BOOLEAN NOT NULL DEFAULT true,
    "created_at" TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    "updated_at" TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX "bookmarks_user_id_index" ON "bookmarks" ("user_id");

-- migrate:down
DROP TABLE "bookmarks";
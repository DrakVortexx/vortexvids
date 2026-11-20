import "server-only";
import { getCurrentUser } from "@/lib/auth";
import { flagOn } from "@/lib/flags";
import { createClient } from "@/lib/supabase/server";
import { createUploadDb } from "./db";
import { readR2Config } from "./env";
import type { HandlerResult, UploadContext } from "./handlers";
import { createR2Client, createR2Storage } from "./r2";
import { createSupabaseStorage } from "./supabase-storage";

/** The real storage (R2 or Supabase), database and session for the upload routes. */
export async function uploadContext(): Promise<UploadContext> {
  const r2 = readR2Config();
  const supabase = await createClient();
  
  // Use R2 if configured, otherwise fall back to Supabase Storage
  const storage = r2 
    ? createR2Storage(createR2Client(r2), r2.bucket)
    : (supabase ? createSupabaseStorage(supabase, "videos") : null);
  
  return {
    storage,
    db: supabase ? createUploadDb(supabase) : null,
    userId: async () => (await getCurrentUser())?.id ?? null,
    flagOn: (userId) => flagOn("upload", userId),
  };
}

/** Reads the JSON body, runs the handler and answers. Never cached. */
export async function runUploadRoute(
  request: Request,
  handler: (body: unknown, ctx: UploadContext) => Promise<HandlerResult>,
): Promise<Response> {
  const body = await request.json().catch(() => null);
  const result = await handler(body, await uploadContext());
  return Response.json(result.body, { status: result.status, headers: { "Cache-Control": "no-store" } });
}

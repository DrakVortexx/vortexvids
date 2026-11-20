import "server-only";

/** The names of the R2 settings. Server only: never prefix them with NEXT_PUBLIC. */
export const R2_ENV = ["R2_ACCOUNT_ID", "R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY", "R2_BUCKET"] as const;

export type R2Config = {
  accountId: string;
  accessKeyId: string;
  secretAccessKey: string;
  bucket: string;
};

/**
 * Reads the R2 settings at request time, like lib/supabase/env.ts, so one
 * Docker image works with whatever is in /opt/vortexvids/.env.
 * Returns null when any of the four is missing.
 */
export function readR2Config(): R2Config | null {
  const env = process.env;
  const [accountId, accessKeyId, secretAccessKey, bucket] = R2_ENV.map((name) => env[name]?.trim());
  if (!accountId || !accessKeyId || !secretAccessKey || !bucket) return null;
  return { accountId, accessKeyId, secretAccessKey, bucket };
}

/**
 * Check if we have storage configured (either R2 or Supabase)
 */
export function hasStorageConfigured(): boolean {
  // R2 is configured
  if (readR2Config() !== null) return true;
  
  // Fall back to Supabase Storage (always available if Supabase is configured)
  return true;
}

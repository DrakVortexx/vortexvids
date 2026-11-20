// Supabase Storage implementation as an alternative to R2
// Uses Supabase's built-in storage buckets for video uploads

import type { SupabaseClient } from "@supabase/supabase-js";
import type { UploadStorage } from "./handlers";

/**
 * UploadStorage implementation using Supabase Storage buckets
 * This is a simpler alternative to R2 that works with just Supabase
 */
export function createSupabaseStorage(supabase: SupabaseClient, bucket: string): UploadStorage {
  return {
    async createMultipart(key: string, mime: string): Promise<string> {
      // For Supabase Storage, we'll use a simple approach:
      // Return a unique upload ID that we can use to track the upload
      return `supabase-${Date.now()}-${Math.random().toString(36).substring(7)}`;
    },

    async presignPart(key: string, uploadId: string, partNumber: number, expiresIn: number): Promise<string> {
      // Create a signed upload URL for this part
      // Supabase Storage supports signed URLs for uploads
      const { data, error } = await supabase.storage
        .from(bucket)
        .createSignedUploadUrl(`${key}.part${partNumber}`, {
          upsert: true,
        });

      if (error || !data) {
        throw new Error(`Failed to create signed URL: ${error?.message || 'Unknown error'}`);
      }

      return data.signedUrl;
    },

    async completeMultipart(key: string, uploadId: string, parts: Array<{ partNumber: number; etag: string }>): Promise<void> {
      // For Supabase, we need to combine the parts into a single file
      // This is a simplified approach - in production you might want to use Supabase Edge Functions
      
      // Get all part files
      const partKeys = parts.map(p => `${key}.part${p.partNumber}`);
      
      // Download all parts (this is simplified - you'd want to stream this)
      const partBlobs: Blob[] = [];
      for (const partKey of partKeys) {
        const { data, error } = await supabase.storage
          .from(bucket)
          .download(partKey);
        
        if (data) {
          partBlobs.push(data);
        }
      }

      // Combine parts into final file
      const finalBlob = new Blob(partBlobs);
      
      // Upload final combined file
      const { error: uploadError } = await supabase.storage
        .from(bucket)
        .upload(key, finalBlob, {
          upsert: true,
          contentType: 'video/mp4', // or get from parts
        });

      if (uploadError) {
        throw new Error(`Failed to complete upload: ${uploadError.message}`);
      }

      // Clean up part files
      await supabase.storage.from(bucket).remove(partKeys);
    },

    async abortMultipart(key: string, uploadId: string): Promise<void> {
      // Clean up any part files that were created
      const { data: files } = await supabase.storage
        .from(bucket)
        .list('', {
          search: `${key}.part`,
        });

      if (files && files.length > 0) {
        const partKeys = files.map(f => f.name);
        await supabase.storage.from(bucket).remove(partKeys);
      }
    },

    async objectSize(key: string): Promise<number | null> {
      // Get file info to check size
      const { data, error } = await supabase.storage
        .from(bucket)
        .list('', {
          search: key,
          limit: 1,
        });

      if (error || !data || data.length === 0) {
        return null;
      }

      // Supabase storage list returns metadata with size
      return data[0].metadata?.size || null;
    },
  };
}

/**
 * Simple single-file upload for Supabase Storage (no multipart)
 * This is more efficient for smaller files
 */
export async function uploadToSupabase(
  supabase: SupabaseClient,
  bucket: string,
  key: string,
  file: Blob,
  contentType: string,
): Promise<{ success: boolean; error?: string }> {
  const { error } = await supabase.storage
    .from(bucket)
    .upload(key, file, {
      contentType,
      upsert: true,
    });

  if (error) {
    return { success: false, error: error.message };
  }

  return { success: true };
}

/**
 * Get a public URL for a video file
 */
export function getPublicUrl(supabase: SupabaseClient, bucket: string, key: string): string {
  const { data } = supabase.storage
    .from(bucket)
    .getPublicUrl(key);
  
  return data.publicUrl;
}

/**
 * Get a signed URL for private video access
 */
export async function getSignedUrl(
  supabase: SupabaseClient,
  bucket: string,
  key: string,
  expiresIn: number = 3600,
): Promise<string | null> {
  const { data, error } = await supabase.storage
    .from(bucket)
    .createSignedUrl(key, expiresIn);

  if (error || !data) {
    return null;
  }

  return data.signedUrl;
}

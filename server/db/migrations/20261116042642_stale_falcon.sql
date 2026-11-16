ALTER TABLE `oauthPending` ADD `ipHash` text;--> statement-breakpoint
CREATE INDEX `oauthPending_ipHash_createdAt_idx` ON `oauthPending` (`ipHash`,`createdAt`);
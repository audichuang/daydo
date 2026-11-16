CREATE TABLE `emailCode` (
	`id` text PRIMARY KEY NOT NULL,
	`email` text NOT NULL,
	`codeHash` text NOT NULL,
	`salt` text NOT NULL,
	`attempts` integer DEFAULT 0 NOT NULL,
	`createdAt` integer NOT NULL,
	`expiresAt` integer NOT NULL,
	`usedAt` integer,
	`pendingId` text,
	`ipHash` text NOT NULL
);
--> statement-breakpoint
CREATE INDEX `emailCode_email_createdAt_idx` ON `emailCode` (`email`,`createdAt`);--> statement-breakpoint
CREATE INDEX `emailCode_ipHash_createdAt_idx` ON `emailCode` (`ipHash`,`createdAt`);
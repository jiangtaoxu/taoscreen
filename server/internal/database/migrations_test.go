package database

import "testing"

func TestMigrationsAreContiguousAndVerified(t *testing.T) {
	all, err := loadMigrations()
	if err != nil {
		t.Fatal(err)
	}
	if len(all) != 4 || all[0].version != 1 || all[1].version != 2 || all[2].version != 3 || all[3].version != 4 {
		t.Fatalf("迁移应从 1 连续编号：%v", len(all))
	}
	if err = verifyApplied(map[int]string{1: all[0].checksum}, all); err != nil {
		t.Fatalf("只执行了第一个迁移时应允许继续升级：%v", err)
	}
	if err = verifyApplied(map[int]string{1: all[0].checksum, 2: all[1].checksum}, all); err != nil {
		t.Fatalf("已部署 OAuth 的数据库应能升级到本地管理员迁移：%v", err)
	}
	if err = verifyApplied(map[int]string{1: all[0].checksum, 2: all[1].checksum, 3: all[2].checksum}, all); err != nil {
		t.Fatalf("已有本地管理员的数据库应能升级到可选动态码：%v", err)
	}
	if err = verifyApplied(map[int]string{1: "changed"}, all); err == nil {
		t.Fatal("已执行迁移的内容被改动时必须拒绝")
	}
	future := map[int]string{}
	for i := 0; i <= len(all); i++ {
		future[i+1] = "x"
	}
	if err = verifyApplied(future, all); err == nil {
		t.Fatal("数据库版本高于程序时必须拒绝")
	}
}

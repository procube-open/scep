package utils

import "testing"

func TestNormalizeDeviceID(t *testing.T) {
	tests := []struct {
		name string
		raw  string
		want string
	}{
		{
			name: "trim and lowercase",
			raw:  "  DEVICE-01  ",
			want: "device-01",
		},
		{
			name: "empty stays empty",
			raw:  "   ",
			want: "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := NormalizeDeviceID(tt.raw); got != tt.want {
				t.Fatalf("want %q, got %q", tt.want, got)
			}
		})
	}
}
